import DatabaseCore
import DatabaseEngine
import EdithExtensionSupport
import Foundation

struct DatabaseWorkerClient: DatabaseBrokerCommandSending {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var engine: DatabaseEngine?
    private nonisolated(unsafe) static var storage: URL?
    private nonisolated(unsafe) static var service = ""
    private nonisolated(unsafe) static var suspended = false

    static func start(root: URL, keychainService: String) {
        lock.withLock {
            guard !suspended else { return }
            storage = root
            service = keychainService
            engine = DatabaseEngine(root: root, keychainService: keychainService)
        }
    }

    static func suspend() -> DatabaseEngine? {
        lock.withLock {
            suspended = true
            return engine
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

    static func credentialStore() throws -> any DatabaseSecretStore {
        guard let service = lock.withLock({ Self.engine == nil ? nil : Self.service }) else {
            throw DatabaseEngineError.stopped
        }
        return try DatabaseKeychainSecretStore(service: service)
    }

    static func restart() async throws {
        let current = lock.withLock { suspended ? nil : engine }
        guard let current else { throw DatabaseEngineError.stopped }
        await current.shutdown()
        let replacement = lock.withLock { () -> DatabaseEngine? in
            guard !suspended, engine === current, let storage else { return nil }
            let replacement = DatabaseEngine(root: storage, keychainService: service)
            engine = replacement
            return replacement
        }
        guard let replacement else { throw DatabaseEngineError.stopped }
        _ = try await replacement.send(.connectionList(.init()))
    }

    func send(_ request: DatabaseBrokerCommandRequest) async throws -> DatabaseBrokerCommandResponse
    {
        guard let current = Self.lock.withLock({ Self.suspended ? nil : Self.engine }) else {
            throw DatabaseEngineError.stopped
        }
        return try await current.send(request)
    }
}

@MainActor enum DatabasePrivacy {
    private static var state: SurfacePrivacyState?

    static func start() {
        if let channel = ExtensionSharedState.current {
            state = SurfacePrivacyState(channel: channel)
        }
    }

    static func refresh() { state?.refresh() }

    static func shutdown() {
        state?.shutdown()
        state = nil
    }

    static var hidden: Bool {
        state?.hides(.databases)
            ?? SurfacePrivacyState.hides(
                .databases, values: ExtensionSharedState.current?.values(for: "presenter") ?? [:])
    }
}
