import DatabaseCore
import DatabaseEngine
import EdithExtensionSupport
import Foundation

struct DatabaseWorkerClient: DatabaseBrokerCommandSending {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var engine: DatabaseEngine?
    private nonisolated(unsafe) static var storage: URL?
    private nonisolated(unsafe) static var service = ""

    static func start(root: URL, keychainService: String) {
        lock.withLock {
            storage = root
            service = keychainService
            engine = DatabaseEngine(root: root, keychainService: keychainService)
        }
    }

    static func shutdown() async {
        let current = lock.withLock { () -> DatabaseEngine? in
            let current = engine
            engine = nil
            storage = nil
            return current
        }
        await current?.shutdown()
    }

    static func restart() async throws {
        let current = lock.withLock { engine }
        guard let current else { throw DatabaseEngineError.stopped }
        await current.shutdown()
        let replacement = lock.withLock { () -> DatabaseEngine? in
            guard engine === current, let storage else { return nil }
            let replacement = DatabaseEngine(root: storage, keychainService: service)
            engine = replacement
            return replacement
        }
        guard let replacement else { throw DatabaseEngineError.stopped }
        _ = try await replacement.send(.connectionList(.init()))
    }

    func send(_ request: DatabaseBrokerCommandRequest) async throws -> DatabaseBrokerCommandResponse {
        guard let current = Self.lock.withLock({ Self.engine }) else {
            throw DatabaseEngineError.stopped
        }
        return try await current.send(request)
    }
}

@MainActor enum DatabasePrivacy {
    private static var state: SurfacePrivacyState?

    static func start() {
        if let channel = ExtensionSharedState.current { state = SurfacePrivacyState(channel: channel) }
    }

    static func refresh() { state?.refresh() }

    static func shutdown() {
        state?.shutdown()
        state = nil
    }

    static var hidden: Bool { state?.hides(.databases) ?? false }
}
