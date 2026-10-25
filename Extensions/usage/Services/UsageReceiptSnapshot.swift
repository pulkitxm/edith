import Darwin
import EdithExtensionSupport
import Foundation

struct UsageReceiptSnapshot: Sendable {
    struct File: Sendable {
        let path: String
        let modifiedAt: Date
        let data: Data
    }
    let context: UsageRemoteCollectionContext
    let files: [File]

    static func decode(_ data: Data, machineID: UUID) throws -> Self {
        guard data.count <= 67_108_864,
            let document = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            Set(document.keys) == ["version", "files", "context"],
            try JSONDecoder().decode(Version.self, from: data).version == 1,
            let rawFiles = document["files"] as? [[String: Any]], rawFiles.count <= 10_000,
            let rawContext = document["context"] as? [String: Any],
            Set(rawContext.keys).isSubset(of: ["machineID", "projects", "timeZone"]),
            let projects = rawContext["projects"] as? [[String: Any]]
        else { throw ExtensionPeerError.invalidRequest }
        for project in projects {
            let required: Set<String> = [
                "cwd", "root", "repositoryID", "repositoryName", "folderName",
            ]
            guard required.isSubset(of: Set(project.keys)),
                Set(project.keys).isSubset(of: required.union(["repositoryURL", "worktree"])),
                project.values.allSatisfy({ $0 is String })
            else { throw ExtensionPeerError.invalidRequest }
        }
        let contextData = try JSONSerialization.data(withJSONObject: rawContext)
        guard contextData.count <= 4_194_304 else { throw ExtensionPeerError.invalidRequest }
        let context = try JSONDecoder().decode(UsageRemoteCollectionContext.self, from: contextData)
        guard context.machineID == machineID else { throw ExtensionPeerError.invalidRequest }
        try context.validate()
        var paths: Set<String> = []
        var bytes = 0
        var files: [File] = []
        for file in rawFiles {
            try Task.checkCancellation()
            guard Set(file.keys) == ["path", "modifiedAt", "data"],
                let path = file["path"] as? String, allowed(path), paths.insert(path).inserted,
                let modified = file["modifiedAt"] as? Double, modified.isFinite,
                modified >= 0, modified <= 253_402_300_799,
                let encoded = file["data"] as? String, encoded.utf8.count <= 11_184_812,
                let payload = Data(base64Encoded: encoded), payload.count <= 8_388_608
            else { throw ExtensionPeerError.invalidRequest }
            if path == ".codex/config.toml" {
                guard let text = String(data: payload, encoding: .utf8),
                    ["fast", "flex", "default", "auto", "priority"].contains(where: {
                        text == "service_tier = \"\($0)\"\n"
                    })
                else { throw ExtensionPeerError.invalidRequest }
            }
            bytes += payload.count
            guard bytes <= 41_943_040 else { throw ExtensionPeerError.invalidRequest }
            files.append(
                File(path: path, modifiedAt: Date(timeIntervalSince1970: modified), data: payload))
        }
        return Self(context: context, files: files)
    }

    func stage(at home: URL) throws {
        try FileManager.default.createDirectory(
            at: home, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        for file in files {
            try Task.checkCancellation()
            var directory = home
            for part in file.path.split(separator: "/").dropLast() {
                directory.appendPathComponent(String(part), isDirectory: true)
                var metadata = stat()
                if lstat(directory.path, &metadata) != 0 {
                    guard errno == ENOENT else { throw UsageNativeFailure.unsafePath }
                    try FileManager.default.createDirectory(
                        at: directory,
                        withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                    guard lstat(directory.path, &metadata) == 0 else {
                        throw UsageNativeFailure.unsafePath
                    }
                }
                guard metadata.st_mode & S_IFMT == S_IFDIR, metadata.st_uid == getuid(),
                    metadata.st_mode & 0o077 == 0
                else { throw UsageNativeFailure.unsafePath }
            }
            let destination = home.appendingPathComponent(file.path)
            var metadata = stat()
            guard lstat(destination.path, &metadata) != 0, errno == ENOENT else {
                throw UsageNativeFailure.unsafePath
            }
            try UsageDataFiles.write(file.data, to: destination)
            try FileManager.default.setAttributes(
                [.modificationDate: file.modifiedAt], ofItemAtPath: destination.path)
        }
        try context.validateStagedHome(home)
    }

    static func allowed(_ path: String) -> Bool {
        guard path.utf8.count <= 4_096, !path.hasPrefix("/"), !path.contains("\\"),
            !path.utf8.contains(0)
        else { return false }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return false }
        if path == ".codex/config.toml" { return true }
        let lower = parts.map { $0.lowercased() }
        guard
            lower.allSatisfy({
                !["credentials", "credential", "secrets", "auth", "plugins", "skills"].contains($0)
            }),
            let name = lower.last,
            !["credential", "secret", "auth", "token", "config"].contains(where: name.contains)
        else { return false }
        let databases = [
            ".local/share/opencode/opencode.db", ".hermes/state.db",
            ".local/share/goose/sessions/sessions.db",
            ".local/share/Block/goose/sessions/sessions.db",
            "Library/Application Support/goose/sessions/sessions.db", ".local/share/kilo/kilo.db",
        ]
        if databases.contains(path) { return true }
        let roots = [
            ".claude/projects", "Library/Application Support/Claude/local-agent-mode-sessions",
            ".codex/sessions", ".codex/archived_sessions", ".local/share/opencode/storage/message",
            ".cursor/chats", ".pi/agent/sessions", ".commandcode/projects", ".local/share/amp",
            ".factory/sessions", ".config/manicode/projects", ".config/manicode-dev/projects",
            ".config/manicode-staging/projects", ".hermes/sessions", ".local/share/goose/sessions",
            ".local/share/Block/goose/sessions", "Library/Application Support/goose/sessions",
            ".local/share/kilo", ".gemini/tmp", ".copilot", ".kimi/sessions", ".kimi-code/sessions",
            ".qwen/projects", ".openclaw", ".clawdbot", ".moltbot", ".moldbot", ".grok/sessions",
        ]
        guard roots.contains(where: { path.hasPrefix($0 + "/") }) else { return false }
        if name == "openclaw-agent.sqlite" {
            return [".openclaw", ".clawdbot", ".moltbot", ".moldbot"].contains(parts[0])
        }
        guard name.hasSuffix(".json") || name.hasSuffix(".jsonl") else { return false }
        if [".openclaw", ".clawdbot", ".moltbot", ".moldbot", ".copilot"].contains(parts[0]),
            !lower.contains("sessions"), !lower.contains("session-state")
        {
            return false
        }
        if parts[0] == ".grok", !["updates.jsonl", "summary.json"].contains(name) { return false }
        if parts[0] == ".factory", !name.hasSuffix(".settings.json") { return false }
        if lower.contains(where: { ["manicode", "manicode-dev", "manicode-staging"].contains($0) }),
            name != "chat-messages.json"
        {
            return false
        }
        if [".kimi", ".kimi-code"].contains(parts[0]), name != "wire.jsonl" { return false }
        if lower.contains("local-agent-mode-sessions"),
            !(lower.contains(".claude") && lower.contains("projects"))
        {
            return false
        }
        return true
    }

    private struct Version: Decodable { let version: Int }
}
