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
    private let storage: ClaudeAccountStorage

    init(directory: URL? = nil) {
        self.directory = directory ?? ClaudeAccountStorage.directory
        storage = ClaudeAccountStorage(directory: self.directory)
    }

    func read() async {
        guard !saving else { return }
        do {
            try await load()
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    func load() async throws {
        state = try await storage.load()
        ready = true
    }

    func save(_ next: ClaudeAccountsState) async {
        guard ready, !saving else { return }
        saving = true
        defer { saving = false }
        do {
            try await persist(next)
            try? UsageAgentOperations.requestLimitsRefresh()
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    func persist(_ next: ClaudeAccountsState) async throws {
        try await storage.save(next)
        state = next
        ready = true
    }

    func account(_ id: UUID?) -> ClaudeAccount? { state.accounts.first { $0.id == id } }
}
