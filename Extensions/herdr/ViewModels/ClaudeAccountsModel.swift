import EdithExtensionSupport
import Foundation
import Observation

@MainActor @Observable final class ClaudeAccountsModel {
    private(set) var state = ClaudeAccountsState()
    private(set) var error: String?
    private(set) var ready = false
    private(set) var saving = false
    private let client: HerdrUIClient?
    let directory: URL
    private var file: URL { directory.appendingPathComponent("accounts.json") }

    init(client: HerdrUIClient? = nil, directory: URL? = nil) {
        self.client = client
        self.directory = directory ?? ExtensionData.root.appendingPathComponent("herdr/accounts")
    }

    func read() async {
        do {
            if let client {
                state = try JSONDecoder().decode(
                    ClaudeAccountsState.self,
                    from: await client.perform("herdr.ui.accounts.read", object: [:]))
            } else {
                try load()
            }
            try state.validate()
            ready = true
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    func load() throws {
        if FileManager.default.fileExists(atPath: file.path) {
            let next = try JSONDecoder().decode(
                ClaudeAccountsState.self, from: Data(contentsOf: file))
            try next.validate()
            state = next
        }
        ready = true
    }

    func save(_ next: ClaudeAccountsState) async {
        guard ready, !saving else { return }
        saving = true
        defer { saving = false }
        do {
            if let client {
                func object(_ value: ClaudeAccountsState) throws -> Any {
                    try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
                }
                let data = try await client.perform(
                    "herdr.ui.accounts.save",
                    object: ["baseline": try object(state), "state": try object(next)])
                state = try JSONDecoder().decode(ClaudeAccountsState.self, from: data)
            } else {
                try persist(next)
            }
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    func persist(_ next: ClaudeAccountsState) throws {
        try next.validate()
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        try JSONEncoder().encode(next).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        state = next
        ready = true
    }

    func account(_ id: UUID?) -> ClaudeAccount? {
        state.accounts.first { $0.id == id }
    }
}

@MainActor enum ClaudeAccountsEngine {
    static func execute(_ operation: String, payload: Data, store: HerdrStore) throws -> Data {
        guard payload.count <= 600_000,
            let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any]
        else { throw ExtensionPeerError.invalidRequest }
        let model = store.claudeAccounts
        try model.load()
        switch operation {
        case "herdr.ui.accounts.read":
            guard object.isEmpty else { throw ExtensionPeerError.invalidRequest }
        case "herdr.ui.accounts.save":
            guard Set(object.keys) == ["baseline", "state"] else {
                throw ExtensionPeerError.invalidRequest
            }
            func decode(_ key: String) throws -> ClaudeAccountsState {
                guard let value = object[key] else { throw ExtensionPeerError.invalidRequest }
                return try JSONDecoder().decode(
                    ClaudeAccountsState.self, from: JSONSerialization.data(withJSONObject: value))
            }
            guard try decode("baseline") == model.state else {
                throw ExtensionPeerError.rejected(
                    "Accounts changed in another view. Reload and try again.")
            }
            try model.persist(decode("state"))
        default: throw ExtensionPeerError.invalidRequest
        }
        return try JSONEncoder().encode(model.state)
    }
}
