import AppKit
import EdithExtensionUI
import EdithExtensionSupport
import Observation

enum ExternalApp: String, Equatable, CaseIterable, Sendable {
    case spotify
    case music

    var displayName: String {
        switch self {
        case .spotify: "Spotify"
        case .music: "Apple Music"
        }
    }

    var bundleID: String {
        switch self {
        case .spotify: "com.spotify.client"
        case .music: "com.apple.Music"
        }
    }

    var notificationName: String {
        switch self {
        case .spotify: "com.spotify.client.PlaybackStateChanged"
        case .music: "com.apple.Music.playerInfo"
        }
    }

    var processName: String {
        switch self {
        case .spotify: "Spotify"
        case .music: "Music"
        }
    }
}

struct ExternalTrack: Equatable, Sendable {
    var app: ExternalApp
    var title: String
    var artist: String
    var isPlaying: Bool
    var duration: TimeInterval
}

enum ExternalNowPlaying {
    static func accepts(app: ExternalApp, existing: ExternalTrack?, incoming: ExternalTrack?)
        -> Bool
    {
        guard let existing, existing.app != app else { return true }
        return !existing.isPlaying && incoming?.isPlaying == true
    }

    static func parse(app: ExternalApp, userInfo: [AnyHashable: Any]) -> ExternalTrack? {
        let state = (userInfo["Player State"] as? String)?.lowercased()
        guard state != "stopped" else { return nil }
        guard let title = (userInfo["Name"] as? String), !title.isEmpty else { return nil }
        let artist = (userInfo["Artist"] as? String) ?? ""
        let durationMS: Double
        switch app {
        case .spotify: durationMS = number(userInfo["Duration"])
        case .music: durationMS = number(userInfo["Total Time"])
        }
        return ExternalTrack(
            app: app, title: title, artist: artist, isPlaying: state == "playing",
            duration: durationMS > 0 ? durationMS / 1000 : 0)
    }

    private static func number(_ value: Any?) -> Double {
        (value as? NSNumber)?.doubleValue ?? 0
    }
}

@MainActor struct ExternalMusicEffects {
    var isInert: Bool
    var observeExternal:
        (ExternalApp, @escaping @MainActor ([AnyHashable: Any]) -> Void) -> NSObjectProtocol?
    var removeExternal: (NSObjectProtocol) -> Void
    var observeCommand: (@escaping @MainActor ([AnyHashable: Any]) -> Void) -> NSObjectProtocol?
    var observeState: (@escaping @MainActor () -> Void) -> NSObjectProtocol?
    var removeLocal: (NSObjectProtocol) -> Void
    var isRunning: (ExternalApp) -> Bool
    var readPlayback: (ExternalApp, String?) async throws -> ExternalPlayback?
    var postState: ([String: Any]) -> Void

    static var live: Self {
        let runner = ExternalPlaybackRunner()
        return Self(
            isInert: false,
            observeExternal: { app, receive in
                DistributedNotificationCenter.default().addObserver(
                    forName: Notification.Name(app.notificationName), object: nil, queue: .main
                ) { note in MainActor.assumeIsolated { receive(note.userInfo ?? [:]) } }
            },
            removeExternal: { DistributedNotificationCenter.default().removeObserver($0) },
            observeCommand: { receive in
                MusicEvents.observe(MusicEvents.Name.nowPlayingCommand) { info in
                    MainActor.assumeIsolated { receive(info) }
                }
            },
            observeState: { receive in
                MusicEvents.observe(MusicEvents.Name.requestNowPlayingState) {
                    MainActor.assumeIsolated { receive() }
                }
            },
            removeLocal: MusicEvents.stopObserving,
            isRunning: {
                !NSRunningApplication.runningApplications(withBundleIdentifier: $0.bundleID).isEmpty
            },
            readPlayback: { app, command in try await runner.run(app: app, command: command) },
            postState: { MusicEvents.post(MusicEvents.Name.nowPlayingState, userInfo: $0) })
    }

    static var inert: Self {
        Self(
            isInert: true, observeExternal: { _, _ in nil }, removeExternal: { _ in },
            observeCommand: { _ in nil }, observeState: { _ in nil }, removeLocal: { _ in },
            isRunning: { _ in false }, readPlayback: { _, _ in nil }, postState: { _ in })
    }
}

@MainActor
@Observable
final class ExternalMusic {
    private(set) var current: ExternalTrack?
    private(set) var playback: ExternalPlayback?
    private(set) var lastError: String?
    @ObservationIgnored private let effects: ExternalMusicEffects
    private var pollingTask: Task<Void, Never>?
    private var commandTask: Task<Void, Never>?
    private var observingPlayback = false
    private var generation: UInt64 = 0
    private var presentationSample = Date.distantPast
    private var presentationTask: Task<Void, Never>?

    private var observers: [(ExternalApp, NSObjectProtocol)] = []

    private var commandObserver: NSObjectProtocol?
    private var stateObserver: NSObjectProtocol?

    init(effects: ExternalMusicEffects? = nil) {
        self.effects = effects ?? .live
    }

    var systemResourceCount: Int {
        observers.count + (commandObserver == nil ? 0 : 1) + (stateObserver == nil ? 0 : 1)
    }

    func start() {
        guard !effects.isInert, observers.isEmpty else { return }
        commandObserver = effects.observeCommand { [weak self] in self?.handle(command: $0) }
        stateObserver = effects.observeState { [weak self] in self?.broadcast() }
        for app in ExternalApp.allCases {
            if let observer = effects.observeExternal(
                app, { [weak self] in self?.handle(app: app, userInfo: $0) })
            {
                observers.append((app, observer))
            }
        }
    }

    func stop() {
        generation &+= 1; presentationSample = .distantPast
        presentationTask?.cancel(); presentationTask = nil
        for (_, observer) in observers { effects.removeExternal(observer) }
        observers.removeAll()
        current = nil; playback = nil
        observePlayback(false)
        commandTask?.cancel(); commandTask = nil
        if let commandObserver { effects.removeLocal(commandObserver) }
        if let stateObserver { effects.removeLocal(stateObserver) }
        commandObserver = nil; stateObserver = nil
    }

    func handle(command info: [AnyHashable: Any]) {
        guard !effects.isInert, let app = current?.app,
            let command = ExternalPlaybackScript.command(info, app: app)
        else { return }
        let previous = commandTask
        commandTask = Task { [weak self] in
            await previous?.value
            guard let self, !Task.isCancelled else { return }
            await refreshPlayback(app: app, command: command)
        }
    }

    func observePlayback(_ active: Bool) {
        guard !effects.isInert, active != observingPlayback else { return }
        observingPlayback = active
        pollingTask?.cancel(); pollingTask = nil
        guard active else { return }
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if lastError == nil {
                    let apps: [ExternalApp]
                    if let track = current {
                        apps = [track.app]
                    } else {
                        apps = ExternalApp.allCases.filter(effects.isRunning)
                    }
                    for app in apps {
                        await refreshPlayback(app: app)
                        if current?.isPlaying == true || lastError != nil { break }
                    }
                }
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
    }

    func retryPlayback() {
        guard !effects.isInert else { return }
        lastError = nil
        guard let app = current?.app else { return }
        commandTask?.cancel()
        commandTask = Task { [weak self] in await self?.refreshPlayback(app: app) }
    }

    func refreshPresentationPlayback(force: Bool = false) async {
        guard !effects.isInert else { return }
        if force { presentationSample = .distantPast; lastError = nil }
        if let task = presentationTask { await task.value; return }
        guard let app = current?.app, Date().timeIntervalSince(presentationSample) >= 2 else {
            return
        }
        presentationSample = .now
        let token = generation
        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await self.refreshPlayback(app: app)
        }
        presentationTask = task
        await withTaskCancellationHandler(
            operation: { await task.value }, onCancel: { task.cancel() })
        if generation == token { presentationTask = nil }
    }

    private func refreshPlayback(app: ExternalApp, command: String? = nil) async {
        guard !effects.isInert else { return }
        let token = generation
        guard effects.isRunning(app)
        else {
            if current?.app == app { current = nil; playback = nil }
            return
        }
        do {
            let next = try await effects.readPlayback(app, command)
            guard !Task.isCancelled, generation == token,
                ExternalNowPlaying.accepts(app: app, existing: current, incoming: next?.track)
            else { return }
            playback = next; current = next?.track; lastError = nil
            broadcast()
        } catch {
            guard generation == token, (current == nil || current?.app == app), !Task.isCancelled
            else { return }
            lastError = error.localizedDescription
        }
    }

    func perform(_ request: MusicTransportRequest) {
        guard !effects.isInert else { return }
        MusicTransportExecution.perform(
            request, sendCommand: { handle(command: $0) }, requestStatus: broadcast)
    }

    func broadcast() {
        guard !effects.isInert else { return }
        var payload: [String: Any] = ["present": current != nil]
        if let track = current {
            payload["app"] = track.app.rawValue
            payload["appName"] = track.app.displayName
            payload["title"] = track.title
            payload["artist"] = track.artist
            payload["isPlaying"] = track.isPlaying
            payload["duration"] = track.duration
            if let playback {
                payload["elapsed"] = playback.elapsed(); payload["volume"] = playback.volume
                payload["shuffling"] = playback.shuffling; payload["looping"] = playback.repeating
            }
        }
        effects.postState(payload)
    }

    func playPause() { perform(.toggle) }
    func next() { perform(.next) }
    func previous() { perform(.previous) }

    private func handle(app: ExternalApp, userInfo: [AnyHashable: Any]) {
        guard !effects.isInert else { return }
        guard let track = ExternalNowPlaying.parse(app: app, userInfo: userInfo) else {
            if current?.app == app { current = nil; playback = nil }
            return
        }
        guard ExternalNowPlaying.accepts(app: app, existing: current, incoming: track) else {
            return
        }
        if current?.title != track.title || current?.artist != track.artist
            || current?.app != track.app
        {
            playback = nil
        }
        current = track
        if var value = playback {
            value.position = value.elapsed(); value.sampledAt = .now; value.track = track
            playback = value
        }
    }
}
