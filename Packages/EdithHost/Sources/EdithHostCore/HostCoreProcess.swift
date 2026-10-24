import Darwin
import EdithExtensionSupport
import Foundation

@MainActor public final class HostCoreProcess {
    public private(set) var ready = false
    public var processIdentifier: Int32? { runtime == nil ? nil : getpid() }
    private let identity: HostIdentity
    private let environment: (@Sendable () -> [String: String])?
    private var runtime: HostCoreRuntime?
    private var tasks: [UUID: (operation: HostCoreOperation, cancel: @MainActor () -> Void)] = [:]
    private var launched = false

    public init(identity: HostIdentity, environment: (@Sendable () -> [String: String])? = nil) {
        self.identity = identity
        self.environment = environment
    }

    public func killForQuit() {
        runtime?.cancel()
        for entry in tasks.values { entry.cancel() }
    }

    public func start() async throws -> HostCoreSnapshot {
        guard !launched else { throw HostWorkerError.rejected }
        launched = true
        do {
            let runtime =
                if let environment {
                    try HostCoreRuntime(identity: identity, environment: environment)
                } else {
                    try HostCoreRuntime(identity: identity)
                }
            self.runtime = runtime
            try await runtime.startCommands()
            ready = true
            return runtime.snapshot()
        } catch {
            await runtime?.shutdown()
            runtime = nil
            throw error
        }
    }

    public func perform(_ operation: HostCoreOperation) async throws -> HostCoreSnapshot {
        guard ready, let runtime, ![.start, .stop, .command].contains(operation) else {
            throw HostWorkerError.rejected
        }
        return try await track(operation) {
            switch operation {
            case .status, .cancel: return runtime.snapshot()
            case .inspect: return try await runtime.inspect()
            case .synchronize: return try await runtime.synchronizeSettings()
            case .restore: return try await runtime.synchronizeSettings(restoreOnly: true)
            case .start, .stop, .command: throw HostWorkerError.rejected
            }
        }
    }

    public func performCommand(
        _ operation: HostAgentCommandOperation, payload: Data = Data("{}".utf8)
    ) async throws -> Data {
        try Task.checkCancellation()
        guard ready, let runtime else {
            throw HostAgentCommandError(.unavailable, "The owned core command service is offline.")
        }
        let result = try await track(.command) {
            try await runtime.command(.init(operation: operation, payload: payload))
        }
        try Task.checkCancellation()
        return try result.encoded()
    }

    @discardableResult public func cancelCurrentTask() -> Bool {
        guard ready else { return false }
        let running = tasks.values.filter { ![.status, .command, .cancel].contains($0.operation) }
        guard !running.isEmpty else { return false }
        for entry in running { entry.cancel() }
        return true
    }

    public func stop() async {
        ready = false
        for entry in tasks.values { entry.cancel() }
        runtime?.cancel()
        await runtime?.shutdown()
        runtime = nil
        tasks.removeAll()
    }

    private func track<Value: Sendable>(
        _ operation: HostCoreOperation, _ work: @escaping @MainActor () async throws -> Value
    ) async throws -> Value {
        guard tasks.count < 8 else { throw HostWorkerError.rejected }
        let token = UUID()
        let outcome = Task { @MainActor in try await work() }
        tasks[token] = (operation, { outcome.cancel() })
        defer { tasks.removeValue(forKey: token) }
        return try await withTaskCancellationHandler {
            try await outcome.value
        } onCancel: {
            outcome.cancel()
        }
    }
}
