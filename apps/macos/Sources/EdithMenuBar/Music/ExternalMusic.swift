import AppKit
import CoreServices
import EdithKit
import Foundation

enum ExternalApp: String {
    case spotify
    case music

    var bundleID: String { self == .spotify ? "com.spotify.client" : "com.apple.Music" }
    var scriptName: String { self == .spotify ? "Spotify" : "Music" }
    var label: String { self == .spotify ? "Spotify" : "Apple Music" }
}

struct ExternalTrack: Equatable {
    var app: ExternalApp
    var title: String
    var artist: String
    var isPlaying: Bool
    var position: Double
    var duration: Double
    var volume: Double
    var artworkURL: String?

    var artKey: String { "\(app.rawValue)|\(title)|\(artist)" }

    var hue: Double {
        let sum = title.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return Double(sum % 360) / 360
    }
}

@MainActor
final class ExternalMusic: ObservableObject {
    @Published private(set) var current: ExternalTrack?
    @Published private(set) var artwork: NSImage?

    private var timer: Timer?
    private var positionAt = Date()

    var isActive: Bool { current != nil }

    func start() {
        guard timer == nil else { return }
        Self.debug("start")
        poll()
        let timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        timer.tolerance = 0.5
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func elapsedNow() -> TimeInterval {
        guard let current else { return 0 }
        guard current.isPlaying else { return current.position }
        return min(current.duration, current.position + Date().timeIntervalSince(positionAt))
    }

    func progressNow() -> Double {
        guard let current, current.duration > 0 else { return 0 }
        return min(1, max(0, elapsedNow() / current.duration))
    }

    var volume: Double { current?.volume ?? 0 }

    func playPause() { control("playpause") }
    func next() { control("next track") }
    func previous() { control("previous track") }

    func seek(to fraction: Double) {
        guard let current else { return }
        let seconds = min(max(fraction, 0), 1) * current.duration
        run("set player position to \(seconds)", app: current.app)
    }

    func setVolume(_ value: Double) {
        guard var track = current else { return }
        track.volume = value
        current = track
        run("set sound volume to \(Int((value * 100).rounded()))", app: track.app)
    }

    private func control(_ command: String) {
        guard let app = current?.app else { return }
        run(command, app: app)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.poll() }
    }

    private func run(_ command: String, app: ExternalApp) {
        _ = Self.runScript("tell application \"\(app.scriptName)\" to \(command)")
    }

    private func poll() {
        let snapshot = Self.readState()
        Self.debug(
            "poll spotifyRunning=\(Self.isRunning(.spotify)) musicRunning=\(Self.isRunning(.music)) "
                + "snapshot=\(snapshot.map { "\($0.app.rawValue)/\($0.title)/playing=\($0.isPlaying)" } ?? "nil") "
                + "lastError=\(Self.lastError ?? "none")")
        apply(snapshot)
    }

    nonisolated(unsafe) static var lastError: String?

    nonisolated static func debug(_ message: String) {
        let line = "\(Date()) \(message)\n"
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("edith-ext-debug.txt")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func apply(_ snapshot: ExternalTrack?) {
        let changed = snapshot?.artKey != current?.artKey
        current = snapshot
        positionAt = Date()
        guard changed else { return }
        artwork = nil
        if let snapshot { loadArtwork(for: snapshot) }
    }

    private func loadArtwork(for track: ExternalTrack) {
        let key = track.artKey
        switch track.app {
        case .spotify:
            guard let raw = track.artworkURL, let url = URL(string: raw) else { return }
            URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
                guard let data, let image = NSImage(data: data) else { return }
                Task { @MainActor in
                    guard self?.current?.artKey == key else { return }
                    self?.artwork = image
                }
            }.resume()
        case .music:
            let descriptor = Self.runScript(
                "tell application \"Music\" to get data of artwork 1 of current track")
            guard let data = descriptor?.data, let image = NSImage(data: data) else { return }
            guard current?.artKey == key else { return }
            artwork = image
        }
    }

    private static func readState() -> ExternalTrack? {
        var fallback: ExternalTrack?
        for app in [ExternalApp.spotify, .music] {
            guard isRunning(app), let track = readTrack(app) else { continue }
            if track.isPlaying { return track }
            if fallback == nil { fallback = track }
        }
        return fallback
    }

    private static func isRunning(_ app: ExternalApp) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID).isEmpty
    }

    private static func permitted(_ app: ExternalApp) -> Bool {
        let target = NSAppleEventDescriptor(bundleIdentifier: app.bundleID)
        let status = target.aeDesc.map {
            AEDeterminePermissionToAutomateTarget($0, typeWildCard, typeWildCard, true)
        }
        if status != noErr { lastError = "AEDetermine status=\(status ?? -1)" }
        return status == noErr
    }

    private static func readTrack(_ app: ExternalApp) -> ExternalTrack? {
        guard permitted(app) else { return nil }
        let artworkField = app == .spotify ? " & linefeed & (artwork url of t)" : ""
        let source = """
            tell application "\(app.scriptName)"
              set s to player state as string
              if s is "stopped" then return "stopped"
              set t to current track
              return s & linefeed & (name of t) & linefeed & (artist of t) & linefeed & ((duration of t) as string) & linefeed & ((player position) as string) & linefeed & ((sound volume) as string)\(artworkField)
            end tell
            """
        guard let output = runScript(source)?.stringValue else { return nil }
        let parts = output.components(separatedBy: "\n")
        guard parts.count >= 6, parts[0] != "stopped" else { return nil }
        let rawDuration = Double(parts[3]) ?? 0
        return ExternalTrack(
            app: app,
            title: parts[1],
            artist: parts[2],
            isPlaying: parts[0] == "playing",
            position: Double(parts[4]) ?? 0,
            duration: app == .spotify ? rawDuration / 1000 : rawDuration,
            volume: (Double(parts[5]) ?? 0) / 100,
            artworkURL: app == .spotify && parts.count > 6 ? parts[6] : nil)
    }

    private static func runScript(_ source: String) -> NSAppleEventDescriptor? {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            lastError = "\(error)"
            return nil
        }
        lastError = nil
        return result
    }
}
