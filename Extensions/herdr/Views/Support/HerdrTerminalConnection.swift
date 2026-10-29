import Observation

@MainActor
@Observable
final class HerdrTerminalConnection {
    static let attempts = 3

    private(set) var error: String?
    private(set) var starting = false
    @ObservationIgnored private var current = 0

    func run(_ connect: @MainActor () async throws -> Void) async -> Bool {
        current += 1
        let mine = current
        error = nil
        starting = true
        defer { if current == mine { starting = false } }
        for _ in 0..<Self.attempts {
            do {
                try await connect()
                return current == mine
            } catch is CancellationError {
                guard current == mine, !Task.isCancelled else { return false }
            } catch {
                guard current == mine, !Task.isCancelled else { return false }
                self.error = error.localizedDescription
                return false
            }
        }
        error = "The terminal could not connect."
        return false
    }
}
