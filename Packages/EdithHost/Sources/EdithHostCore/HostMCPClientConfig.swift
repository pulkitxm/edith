import Foundation

public enum HostMCPClient: String, CaseIterable, Sendable {
    case claude, codex, cursor, vscode

    public static let serverName = "edith"

    public var title: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .cursor: "Cursor"
        case .vscode: "VS Code"
        }
    }

    public var isTOML: Bool { self == .codex }

    var containerKey: String { self == .vscode ? "servers" : "mcpServers" }

    public func configURL(home: URL, codexHome: String? = nil) -> URL {
        switch self {
        case .claude: home.appendingPathComponent(".claude.json")
        case .codex:
            (codexHome.map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".codex"))
                .appendingPathComponent("config.toml")
        case .cursor: home.appendingPathComponent(".cursor/mcp.json")
        case .vscode:
            home.appendingPathComponent("Library/Application Support/Code/User/mcp.json")
        }
    }

    func entry(command: String) -> [String: Any] {
        switch self {
        case .claude:
            ["type": "stdio", "command": command, "args": ["mcp"], "env": [String: String]()]
        case .vscode: ["type": "stdio", "command": command, "args": ["mcp"]]
        case .cursor, .codex: ["command": command, "args": ["mcp"]]
        }
    }

    public func snippet(command: String) -> String {
        if isTOML { return Self.tomlBlock(command: command) }
        let document: [String: Any] = [
            containerKey: [Self.serverName: entry(command: command)]
        ]
        return Self.render(document)
    }

    static func tomlBlock(command: String) -> String {
        "[mcp_servers.\(serverName)]\ncommand = \(quoted(command))\nargs = [\"mcp\"]\n"
    }

    static func quoted(_ value: String) -> String {
        let data = try? JSONSerialization.data(
            withJSONObject: [value], options: [.withoutEscapingSlashes])
        let text = String(decoding: data ?? Data("[\"\"]".utf8), as: UTF8.self)
        return String(text.dropFirst().dropLast())
    }

    static func render(_ document: [String: Any]) -> String {
        let data = try? JSONSerialization.data(
            withJSONObject: document,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data ?? Data("{}".utf8), as: UTF8.self) + "\n"
    }
}

public struct HostMCPInstaller: Sendable {
    public enum State: String, Sendable {
        case registered, outdated, notRegistered, unreadable
    }

    public struct Report: Sendable {
        public let client: HostMCPClient
        public let path: String
        public let exists: Bool
        public let state: State
        public let command: String?
    }

    public struct Outcome: Sendable {
        public enum Action: String, Sendable { case created, updated, unchanged, skipped }
        public let client: HostMCPClient
        public let path: String
        public let action: Action
        public let applied: Bool
        public let snippet: String
        public let note: String?
        public let backup: String?
    }

    private let home: URL
    private let command: String
    private let codexHome: String?

    public init(home: URL, command: String, codexHome: String? = nil) {
        self.home = home; self.command = command; self.codexHome = codexHome
    }

    private func url(_ client: HostMCPClient) -> URL {
        client.configURL(home: home, codexHome: codexHome)
    }

    public func inspect(_ client: HostMCPClient) -> Report {
        let file = url(client)
        let text = try? String(contentsOf: file, encoding: .utf8)
        let exists = FileManager.default.fileExists(atPath: file.path)
        func report(_ state: State, _ registered: String? = nil) -> Report {
            Report(
                client: client, path: file.path, exists: exists, state: state, command: registered)
        }
        guard exists else { return report(.notRegistered) }
        guard let text else { return report(.unreadable) }
        if client.isTOML {
            guard let block = Self.tomlBlockRange(in: Self.lines(text)) else {
                return report(.notRegistered)
            }
            let registered = Self.tomlCommand(Self.lines(text)[block])
            return report(registered == command ? .registered : .outdated, registered)
        }
        guard let root = Self.parseJSON(text) else { return report(.unreadable) }
        guard let container = root[client.containerKey] as? [String: Any] else {
            return report(root[client.containerKey] == nil ? .notRegistered : .unreadable)
        }
        guard let entry = container[HostMCPClient.serverName] else {
            return report(.notRegistered)
        }
        let registered = (entry as? [String: Any])?["command"] as? String
        return report(registered == command ? .registered : .outdated, registered)
    }

    public func status() -> [Report] { HostMCPClient.allCases.map(inspect) }

    public func install(_ client: HostMCPClient, dryRun: Bool) -> Outcome {
        let file = url(client)
        let snippet = client.snippet(command: command)
        func outcome(
            _ action: Outcome.Action, applied: Bool = false, note: String? = nil,
            backup: String? = nil
        ) -> Outcome {
            Outcome(
                client: client, path: file.path, action: action, applied: applied,
                snippet: snippet, note: note, backup: backup)
        }
        let exists = FileManager.default.fileExists(atPath: file.path)
        var original = ""
        if exists {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else {
                return outcome(.skipped, note: "The existing file could not be read as UTF-8.")
            }
            original = text
        }
        let updated: String
        let unchanged: Bool
        do {
            if client.isTOML {
                (updated, unchanged) = try Self.updatedTOML(original, command: command)
            } else {
                (updated, unchanged) = try Self.updatedJSON(
                    original, client: client, command: command)
            }
        } catch let failure as Failure {
            return outcome(.skipped, note: failure.message)
        } catch { return outcome(.skipped, note: error.localizedDescription) }
        if unchanged { return outcome(.unchanged) }
        let action: Outcome.Action = exists ? .updated : .created
        if dryRun { return outcome(action) }
        do {
            var backup: String?
            if exists {
                let copy = file.deletingLastPathComponent().appendingPathComponent(
                    file.lastPathComponent + ".edith-backup")
                try? FileManager.default.removeItem(at: copy)
                try FileManager.default.copyItem(at: file, to: copy)
                backup = copy.path
            } else {
                try FileManager.default.createDirectory(
                    at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            }
            let permissions = (try? FileManager.default.attributesOfItem(atPath: file.path))?[
                .posixPermissions]
            try Data(updated.utf8).write(to: file, options: .atomic)
            if let permissions {
                try FileManager.default.setAttributes(
                    [.posixPermissions: permissions], ofItemAtPath: file.path)
            }
            return outcome(action, applied: true, backup: backup)
        } catch {
            return outcome(
                .skipped, note: "Could not write the file: \(error.localizedDescription)")
        }
    }

    private struct Failure: Error { let message: String }

    private static func parseJSON(_ text: String) -> [String: Any]? {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return [:] }
        return (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
    }

    private static func updatedJSON(_ text: String, client: HostMCPClient, command: String) throws
        -> (String, Bool)
    {
        guard var root = parseJSON(text) else {
            throw Failure(
                message: "The existing file is not plain JSON, so it was left untouched.")
        }
        var container: [String: Any] = [:]
        if let existing = root[client.containerKey] {
            guard let dictionary = existing as? [String: Any] else {
                throw Failure(
                    message:
                        "The existing \"\(client.containerKey)\" value is not an object, so the file was left untouched."
                )
            }
            container = dictionary
        }
        let entry = client.entry(command: command)
        if let current = container[HostMCPClient.serverName] as? [String: Any],
            NSDictionary(dictionary: current).isEqual(to: entry)
        {
            return (text, true)
        }
        container[HostMCPClient.serverName] = entry
        root[client.containerKey] = container
        return (HostMCPClient.render(root), false)
    }

    private static func lines(_ text: String) -> [String] {
        text.components(separatedBy: "\n")
    }

    private static func tomlBlockRange(in lines: [String]) -> Range<Int>? {
        let header = "[mcp_servers.\(HostMCPClient.serverName)]"
        guard
            let start = lines.firstIndex(where: {
                $0.trimmingCharacters(in: .whitespaces) == header
            })
        else { return nil }
        let end =
            lines[(start + 1)...].firstIndex {
                $0.trimmingCharacters(in: .whitespaces).hasPrefix("[")
            } ?? lines.count
        return start..<end
    }

    private static func key(_ line: String, _ name: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix(name) else { return false }
        return trimmed.dropFirst(name.count).trimmingCharacters(in: .whitespaces).hasPrefix("=")
    }

    private static func tomlCommand(_ block: ArraySlice<String>) -> String? {
        guard let line = block.first(where: { key($0, "command") }),
            let equals = line.firstIndex(of: "=")
        else { return nil }
        let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
        guard value.hasPrefix("\""),
            let data = "[\(value)]".data(using: .utf8),
            let array = try? JSONSerialization.jsonObject(with: data) as? [String]
        else { return nil }
        return array.first
    }

    private static func updatedTOML(_ text: String, command: String) throws -> (String, Bool) {
        let desired = HostMCPClient.tomlBlock(command: command)
        var all = lines(text)
        guard let range = tomlBlockRange(in: all) else {
            var prefix = text
            if !prefix.isEmpty, !prefix.hasSuffix("\n") { prefix += "\n" }
            if !prefix.isEmpty { prefix += "\n" }
            return (prefix + desired, false)
        }
        let block = all[range]
        if let args = block.first(where: { key($0, "args") }),
            !args.trimmingCharacters(in: .whitespaces).hasSuffix("]")
        {
            throw Failure(
                message:
                    "The existing [mcp_servers.edith] table uses a multi-line args array, so it was left untouched."
            )
        }
        let compactArgs = block.first(where: { key($0, "args") })?.filter { !$0.isWhitespace }
        if tomlCommand(block) == command, compactArgs == "args=[\"mcp\"]" {
            return (text, true)
        }
        let kept = block.dropFirst().filter { !key($0, "command") && !key($0, "args") }
        let replacement =
            [all[range.lowerBound]]
            + desired.components(separatedBy: "\n").dropFirst().filter {
                !$0.isEmpty
            } + kept
        all.replaceSubrange(range, with: replacement)
        return (all.joined(separator: "\n"), false)
    }
}
