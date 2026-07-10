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

    func start() {
        guard observers.isEmpty else { return }
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
        refreshCurrent()
    }

    func refreshCurrent() {
        let running = ExternalApp.allCases.filter {
            !NSRunningApplication.runningApplications(withBundleIdentifier: $0.bundleID).isEmpty
        }
        guard !running.isEmpty else { return }
        Task.detached { [weak self] in
            var best: ExternalTrack?
            for app in running {
                guard let track = Self.query(app) else { continue }
                if track.isPlaying {
                    best = track
                    break
                }
                if best == nil { best = track }
            }
            if let best { await self?.applyRefreshed(best) }
        }
    }

    private func applyRefreshed(_ track: ExternalTrack) {
        guard current == nil else { return }
        current = track
    }

    private nonisolated static func query(_ app: ExternalApp) -> ExternalTrack? {
        let source = """
            tell application "System Events"
                if not (exists process "\(app.processName)") then return "none"
            end tell
            tell application "\(app.processName)"
                set st to player state as text
                if st is "stopped" then return "none"
                set nm to name of current track
                set ar to artist of current track
                set du to duration of current track
                return st & "|~|" & nm & "|~|" & ar & "|~|" & du
            end tell
            """
        var error: NSDictionary?
        guard
            let result = NSAppleScript(source: source)?.executeAndReturnError(&error).stringValue,
            result != "none"
        else { return nil }
        let parts = result.components(separatedBy: "|~|")
        guard parts.count == 4, !parts[1].isEmpty else { return nil }
        let state = parts[0].lowercased()
        let rawDuration = Double(parts[3]) ?? 0
        let duration: TimeInterval = app == .spotify ? rawDuration / 1000 : rawDuration
        return ExternalTrack(
            app: app, title: parts[1], artist: parts[2], isPlaying: state == "playing",
            duration: duration > 0 ? duration : 0)
    }

    func stop() {
        let center = DistributedNotificationCenter.default()
        for (_, observer) in observers { center.removeObserver(observer) }
        observers.removeAll()
        current = nil
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
