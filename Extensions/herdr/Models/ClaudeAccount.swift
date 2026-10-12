import EdithExtensionSupport
import Foundation

struct ClaudeAccount: Codable, Equatable, Identifiable, Sendable {
    enum Authentication: String, Codable, CaseIterable, Identifiable {
        case oauthToken
        case apiKey
        case browserLogin

        var id: String { rawValue }
        var title: String {
            switch self {
            case .oauthToken: "OAuth token"
            case .apiKey: "API key"
            case .browserLogin: "Claude subscription login"
            }
        }
    }

    var id = UUID()
    var name: String
    var authentication: Authentication = .oauthToken
    var credential = ""

    func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            name.utf8.count <= 128, credential.utf8.count <= 8192,
            !name.utf8.contains(0), !credential.utf8.contains(0)
        else { throw ExtensionPeerError.rejected("Enter a valid account name and credential.") }
    }

    func validateLaunch() throws {
        try validate()
        guard authentication == .browserLogin || !credential.isEmpty else {
            throw ExtensionPeerError.rejected(
                "Enter a credential for this account in launch settings.")
        }
    }

    func launcher(command: String, arguments: [String], directory: URL) throws -> URL {
        try validateLaunch()
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ExtensionPeerError.rejected("Enter a Claude launch command in launch settings.")
        }
        let folder = directory.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var lines = [
            "#!/bin/sh",
            "unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_BASE_URL ANTHROPIC_PROFILE CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX CLAUDE_CODE_USE_FOUNDRY",
            "export CLAUDE_CONFIG_DIR=" + ShellQuote.quote(folder.path),
        ]
        switch authentication {
        case .oauthToken:
            lines.append("export CLAUDE_CODE_OAUTH_TOKEN=" + ShellQuote.quote(credential))
        case .apiKey:
            lines.append("export ANTHROPIC_API_KEY=" + ShellQuote.quote(credential))
        case .browserLogin: break
        }
        lines.append("/bin/rm -f -- \"$0\"")
        lines.append("exec " + HerdrPaneRunCommand.commandText(command, appending: arguments))
        let file = folder.appendingPathComponent("launch-\(UUID().uuidString).sh")
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        return file
    }
}

struct ClaudeAccountsState: Codable, Equatable {
    var accounts: [ClaudeAccount] = []
    var defaultID: UUID?

    func validate() throws {
        guard accounts.count <= 64, Set(accounts.map(\.id)).count == accounts.count,
            defaultID == nil || accounts.contains(where: { $0.id == defaultID })
        else { throw ExtensionPeerError.invalidRequest }
        for account in accounts { try account.validate() }
        guard try JSONEncoder().encode(self).count <= 60_000 else {
            throw ExtensionPeerError.rejected("The saved account credentials are too large.")
        }
    }
}
