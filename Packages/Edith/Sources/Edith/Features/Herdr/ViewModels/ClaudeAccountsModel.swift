import EdithKit
import Foundation
import Observation

@MainActor @Observable final class ClaudeAccountsModel {
    static let shared = ClaudeAccountsModel()
    private(set) var state = ClaudeAccountsState()
    private(set) var error: String?
    private(set) var ready = false
    private(set) var saving = false
    let directory: URL
    private var file: URL { directory.appendingPathComponent("accounts.json") }

    init(directory: URL? = nil) {
        self.directory = directory ?? DataRoot.support.appendingPathComponent("herdr/accounts")
    }

    func read() async {
        guard !saving else { return }
        do {
            try load()
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
            try persist(next)
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

    func account(_ id: UUID?) -> ClaudeAccount? { state.accounts.first { $0.id == id } }
}
