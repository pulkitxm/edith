import Foundation

@MainActor final class StudioBackgroundExportFixture {
    var directory: URL?
    private let shutdown: @MainActor () async throws -> Void

    init(shutdown: @escaping @MainActor () async throws -> Void) {
        self.shutdown = shutdown
    }

    func run<Value>(_ operation: @MainActor () async throws -> Value) async throws -> Value {
        let value: Value
        do {
            value = try await operation()
        } catch {
            try await finish()
            throw error
        }
        try await finish()
        return value
    }

    private func finish() async throws {
        try await shutdown()
        if let directory {
            try FileManager.default.removeItem(at: directory)
            self.directory = nil
        }
    }
}
