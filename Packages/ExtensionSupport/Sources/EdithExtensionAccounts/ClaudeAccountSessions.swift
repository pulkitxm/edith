import Darwin
import Foundation

public enum ClaudeAccountSessions {
    static let ledger = "sessions.jsonl"
    static let maximumBytes = 67_108_864

    public static func launchArguments(account: UUID, directory: URL) throws -> [String] {
        let path = directory.appendingPathComponent(ledger).path
        guard path.hasPrefix("/"), !path.utf8.contains(0),
            !path.contains(where: { $0.isNewline })
        else { throw ClaudeAccountError.invalidRequest }
        let command =
            "umask 077; printf '{\"account\":\"%s\",\"event\":%s}\\n' " + account.uuidString
            + " \"$(cat)\" >> " + quoted(path)
        let settings: [String: Any] = [
            "hooks": ["SessionStart": [["hooks": [["type": "command", "command": command]]]]]
        ]
        let data = try JSONSerialization.data(
            withJSONObject: settings, options: [.sortedKeys, .withoutEscapingSlashes])
        return ["--settings", String(decoding: data, as: UTF8.self)]
    }

    public static func accounts(directory: URL) throws -> [String: UUID] {
        let root = try OwnedAccountFiles.root(directory)
        defer { close(root) }
        guard let data = try OwnedAccountFiles.read(ledger, directory: root, maximum: maximumBytes)
        else { return [:] }
        var result: [String: UUID] = [:]
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard
                let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                let account = (object["account"] as? String).flatMap(UUID.init(uuidString:)),
                let session = (object["event"] as? [String: Any])?["session_id"] as? String,
                !session.isEmpty, session.utf8.count <= 256
            else { continue }
            result[session] = account
        }
        return result
    }

    private static func quoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
