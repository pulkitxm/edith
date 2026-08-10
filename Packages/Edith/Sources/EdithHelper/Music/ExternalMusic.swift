import EdithKit
import AppKit
import Combine

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

@MainActor
final class ExternalMusic: ObservableObject {
    @Published private(set) var current: ExternalTrack?

    private var observers: [(ExternalApp, NSObjectProtocol)] = []

    private var commandObserver: NSObjectProtocol?
    private var stateObserver: NSObjectProtocol?

    func start() {
        guard observers.isEmpty else { return }
        commandObserver = IPC.observe(
            IPC.Name.nowPlayingCommand,
            info: { [weak self] info in
                MainActor.assumeIsolated { self?.handle(command: info) }
            })
        stateObserver = IPC.observe(IPC.Name.requestNowPlayingState) { [weak self] in
            MainActor.assumeIsolated { self?.broadcast() }
        }
        let center = DistributedNotificationCenter.default()
        for app in ExternalApp.allCases {
            let observer = center.addObserver(
                forName: Notification.Name(app.notificationName), object: nil, queue: .main
            ) { [weak self] note in
                MainActor.assumeIsolated {
                    self?.handle(app: app, userInfo: note.userInfo ?? [:])
                }
            }
            observers.append((app, observer))
        }
    }

    func stop() {
        let center = DistributedNotificationCenter.default()
        for (_, observer) in observers { center.removeObserver(observer) }
        observers.removeAll()
        current = nil
    }

    func handle(command info: [AnyHashable: Any]) {
        switch info["action"] as? String ?? "" {
        case "playpause": playPause()
        case "next": next()
        case "previous": previous()
        case "volume":
            if let value = info["value"] as? Double { setVolume(Float(value)) }
        default: break
        }
        broadcast()
    }

    func broadcast() {
        var payload: [String: Any] = ["present": current != nil]
        if let track = current {
            payload["app"] = track.app.rawValue
            payload["appName"] = track.app.displayName
            payload["title"] = track.title
            payload["artist"] = track.artist
            payload["isPlaying"] = track.isPlaying
        }
        IPC.post(IPC.Name.nowPlayingState, userInfo: payload)
    }

    func playPause() { control("playpause") }
    func next() { control("next track") }
    func previous() { control("previous track") }

    func setVolume(_ value: Float) {
        guard let app = current?.app else { return }
        let level = Int(max(0, min(1, value)) * 100)
        let source = """
            tell application "System Events"
                if not (exists process "\(app.processName)") then return
            end tell
            tell application "\(app.processName)" to set sound volume to \(level)
            """
        Task.detached {
            var error: NSDictionary?
            NSAppleScript(source: source)?.executeAndReturnError(&error)
        }
    }

    private func control(_ command: String) {
        guard let app = current?.app else { return }
        let source = """
            tell application "System Events"
                if not (exists process "\(app.processName)") then return
            end tell
            tell application "\(app.processName)" to \(command)
            """
        Task.detached {
            var error: NSDictionary?
            NSAppleScript(source: source)?.executeAndReturnError(&error)
        }
    }

    private func handle(app: ExternalApp, userInfo: [AnyHashable: Any]) {
        guard let track = ExternalNowPlaying.parse(app: app, userInfo: userInfo) else {
            if current?.app == app { current = nil }
            return
        }
        if let existing = current, existing.app != app, existing.isPlaying, !track.isPlaying {
            return
        }
        current = track
    }
}
