import Foundation

public struct MCPServerEntry: Equatable, Sendable {
    public let name: String
    public let command: String
    public let arguments: [String]

    public init(name: String, command: String, arguments: [String]) {
        self.name = name
        self.command = command
        self.arguments = arguments
    }

    public var codexLine: String {
        let joined = arguments.map { "\"\($0)\"" }.joined(separator: ", ")
        return "[mcp_servers.\(name)]\ncommand = \"\(command)\"\nargs = [\(joined)]"
    }

    public var object: [String: Any] {
        ["command": command, "args": arguments]
    }
}

public enum MCPRegistration {
    public static let serverName = "edith"
    public static let exampleCall = "ed usage limits --json"

    public static func entry(
        commandPath: String = CLIInstaller.preferredDirectory().appendingPathComponent("ed").path
    ) -> MCPServerEntry {
        MCPServerEntry(
            name: serverName, command: commandPath, arguments: ["database", "mcp"])
    }

    public static var claudeConfigURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
    }

    public static func merged(
        into document: [String: Any], entry: MCPServerEntry
    ) -> [String: Any] {
        var root = document
        var servers = root["mcpServers"] as? [String: Any] ?? [:]
        servers[entry.name] = entry.object
        root["mcpServers"] = servers
        return root
    }

    public static func isRegistered(
        in document: [String: Any], name: String = serverName
    ) -> Bool {
        (document["mcpServers"] as? [String: Any])?[name] != nil
    }

    @discardableResult
    public static func register(
        url: URL = claudeConfigURL, entry: MCPServerEntry = MCPRegistration.entry(),
        fileManager: FileManager = .default
    ) -> Bool {
        let existing = fileManager.contents(atPath: url.path)
        let document =
            existing.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            ?? [:]
        let updated = merged(into: document, entry: entry)
        guard
            let data = try? JSONSerialization.data(
                withJSONObject: updated, options: [.prettyPrinted, .sortedKeys])
        else { return false }
        return (try? data.write(to: url, options: .atomic)) != nil
    }

    public static func isRegistered(
        url: URL = claudeConfigURL, fileManager: FileManager = .default
    ) -> Bool {
        guard let data = fileManager.contents(atPath: url.path),
            let document = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        return isRegistered(in: document)
    }
}

public enum CLIInstallStatus: Equatable, Sendable {
    case installed(String)
    case missing
    case unknown

    public var detail: String {
        switch self {
        case let .installed(path): "Linked at \(path)."
        case .missing: "Links ed and edith into a folder already on your PATH."
        case .unknown: "Checking where ed is linked."
        }
    }

    public var actionTitle: String? {
        switch self {
        case .installed: nil
        case .missing, .unknown: "Install"
        }
    }

    public static func current(fileManager: FileManager = .default) -> CLIInstallStatus {
        let directory = CLIInstaller.preferredDirectory()
        let tool = directory.appendingPathComponent(CLIInstaller.primaryTool)
        return fileManager.isExecutableFile(atPath: tool.path)
            ? .installed(tool.path) : .missing
    }
}
