import CryptoKit
import EdithExtensionSupport
import Foundation

public struct MachineUsageSnapshotDescriptor: Codable, Sendable {
    public let machineID: UUID
    public let collectionID: UUID
    public let byteCount: Int
    public let sha256: String
}

@MainActor public final class MachineUsageSnapshotStore {
    private struct Entry {
        let machine: Machine
        let data: Data
        let expires: Date
    }
    private let files: MachineRegistry.Files
    private let now: () -> Date
    private var entries: [UUID: Entry] = [:]
    private var stopped = false

    public init(files: MachineRegistry.Files = .init(), now: @escaping () -> Date = Date.init) {
        self.files = files
        self.now = now
    }

    public func insert(_ data: Data, machine: Machine) throws -> MachineUsageSnapshotDescriptor {
        entries = entries.filter { $0.value.expires > now() && selected($0.value.machine) }
        guard !stopped, selected(machine), entries.count < 2 else {
            throw ExtensionPeerError.unavailable
        }
        try MachineUsageReceiptSnapshot.validate(data)
        let id = UUID()
        entries[id] = Entry(machine: machine, data: data, expires: now().addingTimeInterval(900))
        return MachineUsageSnapshotDescriptor(
            machineID: machine.id, collectionID: id, byteCount: data.count,
            sha256: MachineUsageReceiptSnapshot.hash(data))
    }

    public func remove(_ id: UUID) { entries.removeValue(forKey: id) }
    public func shutdown() { stopped = true; entries = [:] }

    public func execute(_ command: String, payload: Data) throws -> Data {
        guard !stopped else { throw ExtensionPeerError.unavailable }
        entries = entries.filter { $0.value.expires > now() && selected($0.value.machine) }
        switch command {
        case "machines.usage.snapshot.result":
            let request = try MachineCommandPayload.decode(
                Result.self, data: payload, required: ["collectionID", "offset", "maximumBytes"])
            guard let entry = entries[request.collectionID], request.offset >= 0,
                request.offset <= entry.data.count, request.maximumBytes > 0,
                request.maximumBytes <= MachineUsageCollectionService.maximumChunkBytes
            else { throw ExtensionPeerError.invalidRequest }
            let end = min(entry.data.count, request.offset + request.maximumBytes)
            return try JSONEncoder().encode(
                Chunk(
                    offset: request.offset, data: entry.data.subdata(in: request.offset..<end),
                    finished: end == entry.data.count))
        case "machines.usage.snapshot.cancel":
            let request = try MachineCommandPayload.decode(
                Cancel.self, data: payload, required: ["collectionID"])
            guard entries.removeValue(forKey: request.collectionID) != nil else {
                throw ExtensionPeerError.invalidRequest
            }
            return Data("{}".utf8)
        default: throw ExtensionPeerError.invalidRequest
        }
    }

    private func selected(_ machine: Machine) -> Bool {
        MachineRegistry.machines(files).filter { $0.id == machine.id } == [machine]
    }
    private struct Result: Decodable {
        let collectionID: UUID; let offset: Int; let maximumBytes: Int
    }
    private struct Cancel: Decodable { let collectionID: UUID }
    private struct Chunk: Encodable { let offset: Int; let data: Data; let finished: Bool }
}

public enum MachineUsageReceiptSnapshot {
    public static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func validate(_ data: Data) throws {
        guard data.count <= 67_108_864,
            let document = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            Set(document.keys).isSubset(of: ["version", "files", "context"]),
            document["version"] as? Int == 1,
            let files = document["files"] as? [[String: Any]], files.count <= 10_000
        else { throw ExtensionPeerError.invalidRequest }
        if let context = document["context"] {
            guard let object = context as? [String: Any],
                Set(object.keys).isSubset(of: ["machineID", "projects", "timeZone"]),
                let projects = object["projects"] as? [[String: Any]], projects.count <= 10_000,
                try JSONSerialization.data(withJSONObject: object).count <= 4_194_304
            else { throw ExtensionPeerError.invalidRequest }
            if let id = object["machineID"] {
                guard let text = id as? String, UUID(uuidString: text) != nil else {
                    throw ExtensionPeerError.invalidRequest
                }
            }
            if let zone = object["timeZone"] {
                guard let text = zone as? String, TimeZone(identifier: text) != nil else {
                    throw ExtensionPeerError.invalidRequest
                }
            }
            for project in projects {
                let required: Set<String> = [
                    "cwd", "root", "repositoryID", "repositoryName", "folderName",
                ]
                guard required.isSubset(of: Set(project.keys)),
                    Set(project.keys).isSubset(of: required.union(["repositoryURL", "worktree"]))
                else { throw ExtensionPeerError.invalidRequest }
                for (key, value) in project {
                    let maximum =
                        ["cwd", "root"].contains(key)
                        ? 4_096 : key == "repositoryID" || key == "repositoryURL" ? 2_048 : 1_024
                    guard let text = value as? String, !text.isEmpty, text.utf8.count <= maximum,
                        !text.unicodeScalars.contains(
                            where: CharacterSet.controlCharacters.contains)
                    else { throw ExtensionPeerError.invalidRequest }
                    if key == "repositoryURL" {
                        guard let url = URLComponents(string: text),
                            ["http", "https"].contains(url.scheme),
                            url.host != nil, url.user == nil, url.password == nil, url.query == nil,
                            url.fragment == nil
                        else { throw ExtensionPeerError.invalidRequest }
                    }
                }
            }
        }
        var paths: Set<String> = []
        var bytes = 0
        for file in files {
            guard Set(file.keys) == ["path", "modifiedAt", "data"],
                let path = file["path"] as? String, allowed(path), paths.insert(path).inserted,
                let modified = file["modifiedAt"] as? Double, modified.isFinite, modified >= 0,
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
        }
    }

    public static func allowed(_ path: String) -> Bool {
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
}
