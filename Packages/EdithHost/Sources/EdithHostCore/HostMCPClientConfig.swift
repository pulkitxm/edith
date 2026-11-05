import Foundation

public enum HostMCPClient: String, CaseIterable, Sendable {
    case claude, codex, cursor, vscode

    public static let serverName = "edith"
    public static let serverArguments = ["mcp"]

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

    var registrationTool: String? {
        switch self {
        case .claude: "claude"
        case .codex: "codex"
        case .cursor, .vscode: nil
        }
    }

    var editsFileWithoutTool: Bool { self != .claude }

    func registerArguments(command: String) -> [String] {
        switch self {
        case .claude:
            ["mcp", "add", "--scope", "user", Self.serverName, "--", command]
                + Self.serverArguments
        default: ["mcp", "add", Self.serverName, "--", command] + Self.serverArguments
        }
    }

    var unregisterArguments: [String]? {
        self == .claude ? ["mcp", "remove", "--scope", "user", Self.serverName] : nil
    }

    func codexDirectory(home: URL, codexHome: String?) -> URL {
        codexHome.map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".codex")
    }

    public func configURL(home: URL, codexHome: String? = nil) -> URL {
        switch self {
        case .claude: home.appendingPathComponent(".claude.json")
        case .codex:
            codexDirectory(home: home, codexHome: codexHome).appendingPathComponent("config.toml")
        case .cursor: home.appendingPathComponent(".cursor/mcp.json")
        case .vscode:
            home.appendingPathComponent("Library/Application Support/Code/User/mcp.json")
        }
    }

    func presenceURLs(home: URL, codexHome: String?) -> [URL] {
        switch self {
        case .claude: [home.appendingPathComponent(".claude"), configURL(home: home)]
        case .codex: [codexDirectory(home: home, codexHome: codexHome)]
        case .cursor: [home.appendingPathComponent(".cursor")]
        case .vscode: [home.appendingPathComponent("Library/Application Support/Code")]
        }
    }

    func entry(command: String) -> [String: Any] {
        switch self {
        case .claude:
            [
                "type": "stdio", "command": command, "args": Self.serverArguments,
                "env": [String: String](),
            ]
        case .vscode: ["type": "stdio", "command": command, "args": Self.serverArguments]
        case .cursor, .codex: ["command": command, "args": Self.serverArguments]
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
        let data =
            (try? JSONSerialization.data(withJSONObject: document, options: [.sortedKeys]))
            ?? Data("{}".utf8)
        if let value = try? JSONDecoder().decode(HostCLIJSON.self, from: data) {
            return HostCoreCLIJSONFormatter.string(value) + "\n"
        }
        let pretty = try? JSONSerialization.data(
            withJSONObject: document,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return String(decoding: pretty ?? data, as: UTF8.self) + "\n"
    }

    static func shellLine(_ words: [String]) -> String {
        let safe = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_./=:@+%,")
        return words.map { word in
            if !word.isEmpty, word.unicodeScalars.allSatisfy(safe.contains) { return word }
            return "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }.joined(separator: " ")
    }
}

public struct HostMCPToolRunner: Sendable {
    public struct Result: Sendable {
        public let status: Int32
        public let output: String
        public init(status: Int32, output: String) { self.status = status; self.output = output }
    }

    public let locate: @Sendable (String) -> URL?
    public let run: @Sendable (URL, [String]) -> Result

    public init(
        locate: @escaping @Sendable (String) -> URL?,
        run: @escaping @Sendable (URL, [String]) -> Result
    ) {
        self.locate = locate; self.run = run
    }

    public static let none = HostMCPToolRunner(
        locate: { _ in nil }, run: { _, _ in Result(status: 127, output: "") })

    public static func system(home: URL, path: [String]) -> HostMCPToolRunner {
        let directories =
            path.filter { $0.hasPrefix("/") }
            + [
                home.appendingPathComponent(".local/bin").path,
                home.appendingPathComponent(".claude/local").path,
                "/opt/homebrew/bin", "/usr/local/bin",
            ]
        return HostMCPToolRunner(
            locate: { name in
                directories.lazy.map { URL(fileURLWithPath: $0).appendingPathComponent(name) }
                    .first { FileManager.default.isExecutableFile(atPath: $0.path) }
            },
            run: { executable, arguments in
                let process = Process()
                let pipe = Pipe()
                process.executableURL = executable
                process.arguments = arguments
                process.standardInput = FileHandle.nullDevice
                process.standardOutput = pipe
                process.standardError = pipe
                var environment = ProcessInfo.processInfo.environment
                environment["PATH"] = (directories + ["/usr/bin", "/bin"]).joined(separator: ":")
                process.environment = environment
                do { try process.run() } catch {
                    return Result(status: 127, output: error.localizedDescription)
                }
                let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + 60, execute: deadline)
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                deadline.cancel()
                return Result(
                    status: process.terminationStatus,
                    output: String(decoding: data.prefix(16 * 1024), as: UTF8.self))
            })
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
        public let clientFound: Bool
        public let state: State
        public let command: String?
    }

    public struct Outcome: Sendable {
        public enum Action: String, Sendable {
            case created, updated, unchanged, skipped, manual, notFound
        }
        public let client: HostMCPClient
        public let path: String
        public let action: Action
        public let applied: Bool
        public let snippet: String
        public let run: [String]?
        public let note: String?
        public let backup: String?

        public var runLine: String? { run.map(HostMCPClient.shellLine) }
    }

    private let home: URL
    private let command: String
    private let codexHome: String?
    private let tools: HostMCPToolRunner

    public init(
        home: URL, command: String, codexHome: String? = nil, tools: HostMCPToolRunner = .none
    ) {
        self.home = home; self.command = command; self.codexHome = codexHome; self.tools = tools
    }

    private func url(_ client: HostMCPClient) -> URL {
        client.configURL(home: home, codexHome: codexHome)
    }

    public func isPresent(_ client: HostMCPClient) -> Bool {
        if let tool = client.registrationTool, tools.locate(tool) != nil { return true }
        return client.presenceURLs(home: home, codexHome: codexHome).contains {
            FileManager.default.fileExists(atPath: $0.path)
        }
    }

    public func inspect(_ client: HostMCPClient) -> Report {
        let file = url(client)
        let text = try? String(contentsOf: file, encoding: .utf8)
        let exists = FileManager.default.fileExists(atPath: file.path)
        let found = isPresent(client)
        func report(_ state: State, _ registered: String? = nil) -> Report {
            Report(
                client: client, path: file.path, exists: exists, clientFound: found, state: state,
                command: registered)
        }
        guard exists else { return report(.notRegistered) }
        guard let text else { return report(.unreadable) }
        if client.isTOML {
            let all = Self.lines(text)
            guard let block = Self.tomlBlockRange(in: all) else { return report(.notRegistered) }
            let registered = Self.tomlCommand(all[block])
            let current = registered == command && Self.tomlArgsMatch(all[block])
            return report(current ? .registered : .outdated, registered)
        }
        guard let root = Self.parseJSON(text) else { return report(.unreadable) }
        guard let container = root[client.containerKey] as? [String: Any] else {
            return report(root[client.containerKey] == nil ? .notRegistered : .unreadable)
        }
        guard let entry = container[HostMCPClient.serverName] else {
            return report(.notRegistered)
        }
        let object = entry as? [String: Any]
        let registered = object?["command"] as? String
        let current =
            registered == command && object?["args"] as? [String] == HostMCPClient.serverArguments
        return report(current ? .registered : .outdated, registered)
    }

    public func status() -> [Report] { HostMCPClient.allCases.map(inspect) }

    public func install(_ client: HostMCPClient, dryRun: Bool, onlyIfPresent: Bool = false)
        -> Outcome
    {
        let file = url(client)
        let snippet = client.snippet(command: command)
        func outcome(
            _ action: Outcome.Action, applied: Bool = false, run: [String]? = nil,
            note: String? = nil, backup: String? = nil
        ) -> Outcome {
            Outcome(
                client: client, path: file.path, action: action, applied: applied,
                snippet: snippet, run: run, note: note, backup: backup)
        }
        let report = inspect(client)
        if report.state == .registered { return outcome(.unchanged) }
        if onlyIfPresent, !isPresent(client) { return outcome(.notFound) }
        if let tool = client.registrationTool {
            let register = [tool] + client.registerArguments(command: command)
            let action: Outcome.Action = report.state == .outdated ? .updated : .created
            if let executable = tools.locate(tool) {
                if dryRun { return outcome(action, run: register) }
                var steps = [Array(register.dropFirst())]
                if report.state == .outdated, let remove = client.unregisterArguments {
                    steps.insert(remove, at: 0)
                }
                let failure = steps.lazy.compactMap { step -> String? in
                    let result = tools.run(executable, step)
                    guard result.status != 0 else { return nil }
                    let detail = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
                    return "\(HostMCPClient.shellLine([tool] + step)) exited with status \(result.status)"
                        + (detail.isEmpty ? "." : ": " + String(detail.prefix(400)))
                }.first
                guard let failure else { return outcome(action, applied: true, run: register) }
                if !client.editsFileWithoutTool {
                    return outcome(.skipped, run: register, note: failure)
                }
            } else if !client.editsFileWithoutTool {
                return outcome(
                    .manual, run: register, note: "The \(tool) command was not found on this Mac.")
            }
        }
        let edit = installFile(client, file: file, dryRun: dryRun)
        return outcome(edit.action, applied: edit.applied, note: edit.note, backup: edit.backup)
    }

    private func installFile(_ client: HostMCPClient, file: URL, dryRun: Bool) -> (
        action: Outcome.Action, applied: Bool, note: String?, backup: String?
    ) {
        let exists = FileManager.default.fileExists(atPath: file.path)
        var original = ""
        if exists {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else {
                return (.skipped, false, "The existing file could not be read as UTF-8.", nil)
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
            return (.skipped, false, failure.message, nil)
        } catch { return (.skipped, false, error.localizedDescription, nil) }
        if unchanged { return (.unchanged, false, nil, nil) }
        let action: Outcome.Action = exists ? .updated : .created
        if dryRun { return (action, false, nil, nil) }
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
            return (action, true, nil, backup)
        } catch {
            return (.skipped, false, "Could not write the file: \(error.localizedDescription)", nil)
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

    private static func tomlArgsMatch(_ block: ArraySlice<String>) -> Bool {
        block.first(where: { key($0, "args") })?.filter { !$0.isWhitespace } == "args=[\"mcp\"]"
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
        if tomlCommand(block) == command, tomlArgsMatch(block) { return (text, true) }
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
