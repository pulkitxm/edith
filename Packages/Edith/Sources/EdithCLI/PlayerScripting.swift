import Foundation

public enum PlayerScript {
    public static let separator = "\u{1F}"
    public static let notRunningMarker = "norun"

    public static func guardClause(_ process: String) -> String {
        """
        tell application "System Events"
        \tif not (exists process "\(process)") then return "\(notRunningMarker)"
        end tell
        """
    }

    public static func snapshot(_ player: MusicPlayer) -> String? {
        guard let process = player.processName else { return nil }
        let scale = player == .spotify ? " / 1000" : ""
        return """
            \(guardClause(process))
            set fieldBreak to (character id 31)
            set playState to "stopped"
            set trackTitle to ""
            set trackArtist to ""
            set trackElapsed to 0
            set trackDuration to 0
            set levelPercent to 0
            tell application "\(process)"
            \tset playState to (player state as string)
            \ttry
            \t\tset levelPercent to sound volume
            \tend try
            \ttry
            \t\tset trackTitle to name of current track
            \t\tset trackArtist to artist of current track
            \t\tset trackDuration to (duration of current track)\(scale)
            \t\tset trackElapsed to player position
            \tend try
            end tell
            return "ok" & fieldBreak & playState & fieldBreak & trackTitle & fieldBreak \
            & trackArtist & fieldBreak & (trackElapsed as string) & fieldBreak \
            & (trackDuration as string) & fieldBreak & (levelPercent as string)
            """
    }

    public static func command(_ action: PlayerAction, on player: MusicPlayer) -> String? {
        guard let process = player.processName else { return nil }
        let body = verbs(action, on: player).map { "\t\($0)" }.joined(separator: "\n")
        return """
            \(guardClause(process))
            tell application "\(process)"
            \(body)
            end tell
            return "ok"
            """
    }

    public static func verbs(_ action: PlayerAction, on player: MusicPlayer) -> [String] {
        switch action {
        case .play: return ["play"]
        case .pause: return ["pause"]
        case .stop:
            return player == .spotify ? ["pause", "set player position to 0"] : ["stop"]
        case .toggle: return ["playpause"]
        case .next: return ["next track"]
        case .previous: return ["previous track"]
        case let .volume(level):
            let percent = Int((min(max(level, 0), 1) * 100).rounded())
            return ["set sound volume to \(percent)"]
        }
    }

    public static func parse(_ output: String, player: MusicPlayer) -> PlayerSnapshot {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != notRunningMarker else { return PlayerSnapshot(player: player) }
        let fields = trimmed.components(separatedBy: separator)
        guard fields.count >= 7, fields[0] == "ok" else {
            return PlayerSnapshot(player: player, isRunning: true)
        }
        let state = fields[1].lowercased()
        let level = Double(fields[6]).map { min(max($0 / 100, 0), 1) }
        return PlayerSnapshot(
            player: player, isRunning: true, isPlaying: state == "playing",
            title: fields[2], artist: fields[3],
            elapsedSeconds: Double(fields[4]) ?? 0, durationSeconds: Double(fields[5]) ?? 0,
            volume: level)
    }
}

public enum AppleScriptHost {
    public static let automationDeniedCode = "-1743"
    public static let notRunningCode = "-600"

    public static func execute(_ source: String, timeout: TimeInterval) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-"]
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        do {
            try process.run()
        } catch {
            throw CLIFailure.unavailable(
                "could not run osascript", hint: error.localizedDescription)
        }
        input.fileHandleForWriting.write(Data(source.utf8))
        try? input.fileHandleForWriting.close()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline { usleep(20_000) }
        if process.isRunning {
            process.terminate()
            throw CLIFailure.unavailable(
                "the player did not answer in time",
                hint: "macOS may be waiting on an Automation prompt; approve it and retry")
        }
        let out =
            String(
                data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err =
            String(
                data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else { throw failure(from: err) }
        return out
    }

    public static func failure(from stderr: String) -> CLIFailure {
        let text = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.contains(automationDeniedCode) || text.lowercased().contains("not authorized") {
            return CLIFailure.unavailable(
                "macOS has not granted this command line Automation access",
                hint:
                    "allow it in System Settings > Privacy & Security > Automation, then retry")
        }
        if text.contains(notRunningCode) {
            return CLIFailure.unavailable("that player is not running")
        }
        return CLIFailure.unavailable(
            "the player refused the command", hint: text.isEmpty ? nil : text)
    }
}

public enum ExternalPlayers {
    public static func snapshot(_ player: MusicPlayer, timeout: TimeInterval = 6)
        -> PlayerSnapshot
    {
        guard let source = PlayerScript.snapshot(player) else {
            return PlayerSnapshot(player: player)
        }
        guard let output = try? CLIEnvironment.runAppleScript(source, timeout) else {
            return PlayerSnapshot(player: player)
        }
        return PlayerScript.parse(output, player: player)
    }

    public static func send(
        _ action: PlayerAction, to player: MusicPlayer, timeout: TimeInterval = 6
    ) throws {
        guard let source = PlayerScript.command(action, on: player) else {
            throw CLIFailure("\(player.displayName) is not driven by AppleScript")
        }
        let output = try CLIEnvironment.runAppleScript(source, timeout)
        guard
            output.trimmingCharacters(in: .whitespacesAndNewlines)
                != PlayerScript.notRunningMarker
        else {
            throw CLIFailure.unavailable(
                "\(player.displayName) is not running",
                hint: "open \(player.displayName), then retry")
        }
    }
}
