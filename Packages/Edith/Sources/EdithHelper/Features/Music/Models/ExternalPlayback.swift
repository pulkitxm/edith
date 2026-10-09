import AppKit
import EdithKit

struct ExternalPlayback: Equatable, Sendable {
    var track: ExternalTrack
    var position: Double
    var volume: Double
    var shuffling: Bool
    var repeating: Bool
    var canShuffle: Bool
    var canRepeat: Bool
    var sampledAt: Date = .now

    func elapsed(at date: Date = .now) -> Double {
        min(
            track.duration,
            max(0, position + (track.isPlaying ? max(0, date.timeIntervalSince(sampledAt)) : 0)))
    }
}

enum ExternalPlaybackScript {
    static func command(_ info: [AnyHashable: Any], app: ExternalApp) -> String? {
        let action = (info["action"] as? String ?? "").lowercased()
        switch action {
        case "playpause": return "playpause"
        case "resume": return "play"
        case "pause": return "pause"
        case "next": return "next track"
        case "previous": return "previous track"
        case "seek", "volume":
            guard let value = info["value"] as? Double, value.isFinite else { return nil }
            let fraction = min(1, max(0, value))
            if action == "volume" {
                return "set sound volume to \(Int((fraction * 100).rounded()))"
            }
            let scale = app == .spotify ? " / 1000" : ""
            return "set player position to ((duration of current track)\(scale)) * \(fraction)"
        case "shuffle", "loop":
            guard let enabled = info["value"] as? Bool else { return nil }
            let value = enabled ? "true" : "false"
            if action == "shuffle" {
                return "set \(app == .spotify ? "shuffling" : "shuffle enabled") to \(value)"
            }
            if app == .spotify { return "set repeating to \(value)" }
            return "set song repeat to \(enabled ? "all" : "off")"
        default: return nil
        }
    }

    static func source(app: ExternalApp, command: String? = nil) -> String {
        let scale = app == .spotify ? " / 1000" : ""
        let shuffle = app == .spotify ? "shuffling" : "shuffle enabled"
        let repeating = app == .spotify ? "repeating" : "(song repeat is not off)"
        let canShuffle = app == .spotify ? "shuffling enabled" : "true"
        let canRepeat = app == .spotify ? "repeating enabled" : "true"
        return """
            with timeout of 4 seconds
                if application id "\(app.bundleID)" is not running then return {}
                tell application id "\(app.bundleID)"
                    \(command ?? "")
                    if player state is stopped then return {}
                    return {name of current track, artist of current track, player state is playing, \
            (duration of current track)\(scale), player position, sound volume, \
            \(shuffle), \(repeating), \(canShuffle), \(canRepeat)}
                end tell
            end timeout
            """
    }

    static func parse(_ result: NSAppleEventDescriptor, app: ExternalApp) -> ExternalPlayback? {
        guard result.numberOfItems == 10, let title = result.atIndex(1)?.stringValue,
            !title.isEmpty
        else { return nil }
        func number(_ index: Int) -> Double {
            let value = result.atIndex(index)?.doubleValue ?? 0
            return value.isFinite ? max(0, value) : 0
        }
        return ExternalPlayback(
            track: .init(
                app: app, title: title, artist: result.atIndex(2)?.stringValue ?? "",
                isPlaying: result.atIndex(3)?.booleanValue ?? false, duration: number(4)),
            position: number(5), volume: min(1, number(6) / 100),
            shuffling: result.atIndex(7)?.booleanValue ?? false,
            repeating: result.atIndex(8)?.booleanValue ?? false,
            canShuffle: result.atIndex(9)?.booleanValue ?? false,
            canRepeat: result.atIndex(10)?.booleanValue ?? false)
    }
}

actor ExternalPlaybackRunner {
    func run(app: ExternalApp, command: String? = nil) throws -> ExternalPlayback? {
        guard
            let script = NSAppleScript(
                source: ExternalPlaybackScript.source(app: app, command: command))
        else {
            throw CocoaError(.executableNotLoadable)
        }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            let denied = (error[NSAppleScript.errorNumber] as? Int) == -1743
            throw NSError(
                domain: "ExternalPlayback", code: denied ? -1743 : 1,
                userInfo: [
                    NSLocalizedDescriptionKey: denied
                        ? "Allow Edith to control \(app.displayName) in System Settings > Privacy & Security > Automation, then retry."
                        : "\(app.displayName) could not complete playback control. Retry after opening the player."
                ])
        }
        return ExternalPlaybackScript.parse(result, app: app)
    }
}
