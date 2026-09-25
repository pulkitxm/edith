import AppKit
import EdithKit
import Foundation

struct AttentionPlayback: Equatable, Sendable {
    var media: AttentionMedia
    var bundleID: String?
    var expiresAt: Date?

    var key: String {
        [media.service, media.artist ?? "", media.album ?? "", media.title]
            .joined(separator: "\u{1F}")
    }
}

enum AttentionPlaybackParser {
    static let players: [(notification: String, bundleID: String, service: String)] = [
        ("com.spotify.client.PlaybackStateChanged", "com.spotify.client", "Spotify"),
        ("com.apple.Music.playerInfo", "com.apple.Music", "Apple Music"),
    ]

    static func external(service: String, bundleID: String, userInfo: [AnyHashable: Any])
        -> AttentionPlayback?
    {
        let state = (userInfo["Player State"] as? String)?.lowercased()
        guard state == "playing", let title = userInfo["Name"] as? String, !title.isEmpty
        else { return nil }
        return AttentionPlayback(
            media: AttentionMedia(
                title: title, artist: text(userInfo["Artist"]), album: text(userInfo["Album"]),
                service: service, kind: "audio", playing: true),
            bundleID: bundleID)
    }

    static func edith(_ userInfo: [AnyHashable: Any], now: Date) -> AttentionPlayback? {
        guard (userInfo["isPlaying"] as? Bool) == true,
            let track = userInfo["track"] as? String, !track.isEmpty
        else { return nil }
        let name = URL(fileURLWithPath: track).deletingPathExtension().lastPathComponent
        let folder = URL(fileURLWithPath: track).deletingLastPathComponent().lastPathComponent
        let duration = number(userInfo["duration"])
        let elapsed = number(userInfo["elapsed"])
        let remaining = duration > 0 ? max(0, duration - elapsed) : 600
        return AttentionPlayback(
            media: AttentionMedia(
                title: name, album: folder.isEmpty || folder == "." ? nil : folder,
                service: "Edith", kind: "audio", playing: true),
            bundleID: nil, expiresAt: now.addingTimeInterval(remaining + 30))
    }

    private static func text(_ value: Any?) -> String? {
        guard let value = value as? String, !value.isEmpty else { return nil }
        return value
    }

    private static func number(_ value: Any?) -> Double {
        (value as? NSNumber)?.doubleValue ?? (value as? Double) ?? 0
    }
}

@MainActor
final class AttentionMediaObserver {
    private(set) var playing: [String: AttentionPlayback] = [:]
    private var observers: [NSObjectProtocol] = []
    private var edithObserver: NSObjectProtocol?

    func start() {
        guard observers.isEmpty, edithObserver == nil else { return }
        let center = DistributedNotificationCenter.default()
        for player in AttentionPlaybackParser.players {
            observers.append(
                center.addObserver(
                    forName: Notification.Name(player.notification), object: nil, queue: .main
                ) { [weak self] note in
                    let playback = AttentionPlaybackParser.external(
                        service: player.service, bundleID: player.bundleID,
                        userInfo: note.userInfo ?? [:])
                    MainActor.assumeIsolated { self?.playing[player.service] = playback }
                })
        }
        edithObserver = IPC.observe(IPC.Name.musicState) { [weak self] info in
            let playback = AttentionPlaybackParser.edith(info, now: Date())
            Task { @MainActor in self?.playing["Edith"] = playback }
        }
        IPC.post(IPC.Name.requestMusicState)
    }

    func stop() {
        let center = DistributedNotificationCenter.default()
        observers.forEach(center.removeObserver)
        observers.removeAll()
        if let edithObserver { IPC.stopObserving(edithObserver) }
        edithObserver = nil
        playing.removeAll()
    }

    func current(now: Date) -> [AttentionPlayback] {
        playing = playing.filter { _, playback in
            if let expiresAt = playback.expiresAt, now > expiresAt { return false }
            if let bundleID = playback.bundleID,
                NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
            {
                return false
            }
            return true
        }
        return Array(playing.values)
    }

    func set(_ playback: AttentionPlayback?, for service: String) {
        playing[service] = playback
    }
}
