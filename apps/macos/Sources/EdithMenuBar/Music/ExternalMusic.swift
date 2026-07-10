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

    var readScript: String {
        """
        tell application "System Events"
            if not (exists process "\(processName)") then return ""
        end tell
        tell application "\(processName)"
            if player state is not playing then return ""
            return (name of current track) & linefeed & (artist of current track) & linefeed & (duration of current track as text)
        end tell
        """
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

    static func parseScriptOutput(app: ExternalApp, output: String) -> ExternalTrack? {
        let lines = output.components(separatedBy: "\n")
        guard lines.count >= 3, !lines[0].isEmpty else { return nil }
        let raw = Double(lines[2].trimmingCharacters(in: .whitespaces)) ?? 0
        let duration = app == .spotify ? raw / 1000 : raw
        return ExternalTrack(
            app: app, title: lines[0], artist: lines[1], isPlaying: true,
            duration: duration > 0 ? duration : 0)
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
        readCurrent()
    }

    func readCurrent() {
        Task { [weak self] in
            let track = await Task.detached { ExternalMusic.readPlaying() }.value
            guard let self, let track else { return }
            self.applyRead(track)
        }
    }

    private func applyRead(_ track: ExternalTrack) {
        if current == nil { current = track }
    }

    private nonisolated static func readPlaying() -> ExternalTrack? {
        for app in ExternalApp.allCases {
            var error: NSDictionary?
            guard let script = NSAppleScript(source: app.readScript) else { continue }
            let result = script.executeAndReturnError(&error)
            guard error == nil, let output = result.stringValue, !output.isEmpty else { continue }
            if let track = ExternalNowPlaying.parseScriptOutput(app: app, output: output) {
                return track
            }
        }
        return nil
    }

    func stop() {
        let center = DistributedNotificationCenter.default()
        for (_, observer) in observers { center.removeObserver(observer) }
        observers.removeAll()
        current = nil
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
