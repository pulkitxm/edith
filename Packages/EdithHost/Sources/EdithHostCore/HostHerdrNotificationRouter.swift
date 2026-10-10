import Foundation

@MainActor
public final class HostHerdrNotificationLease {
    public let configuration: HostWorkerConfiguration
    public let presentationID: UUID
    public let enginePID: Int32
    public let engineGeneration: String
    private let validateOrigin: @MainActor () throws -> Void
    private let invoke: @MainActor (String, Data) async throws -> Data
    private let open: @MainActor (HostWorkerNavigationRequest) async throws -> Void

    public init(
        configuration: HostWorkerConfiguration, presentationID: UUID,
        enginePID: Int32, engineGeneration: String,
        validateOrigin: @escaping @MainActor () throws -> Void,
        invoke: @escaping @MainActor (String, Data) async throws -> Data,
        open: @escaping @MainActor (HostWorkerNavigationRequest) async throws -> Void
    ) {
        self.configuration = configuration; self.presentationID = presentationID
        self.enginePID = enginePID; self.engineGeneration = engineGeneration
        self.validateOrigin = validateOrigin; self.invoke = invoke; self.open = open
    }

    public func validate() throws { try validateOrigin() }

    public func apply(_ request: HostHerdrNotificationRequest, version: String) async throws {
        guard configuration.extensionID == "herdr", configuration.version == version,
            !configuration.recoveryOnly, enginePID > 1, !engineGeneration.isEmpty
        else { throw HostWorkerError.rejected }
        try validateOrigin()
        try Task.checkCancellation()
        let data = try await invoke("herdr.ui.notification.open", JSONEncoder().encode(request))
        try Task.checkCancellation()
        try validateOrigin()
        let target = try HostHerdrWindowTarget.decode(data)
        guard target.location == "herdr.agent" else { throw HostWorkerError.rejected }
        let retained = HostHerdrWindowLease(
            target: target, invoke: invoke, validateOrigin: validateOrigin)
        try await retained.validate()
        try Task.checkCancellation()
        try validateOrigin()
        try await open(
            HostWorkerNavigationRequest(
                configuration: configuration, presentationID: presentationID, herdrWindow: target))
        try Task.checkCancellation()
        try validateOrigin()
    }
}

@MainActor
public final class HostHerdrNotificationRouter {
    private let currentVersion: @MainActor () -> String?
    private let prepare: @MainActor (String) async throws -> HostHerdrNotificationLease
    private var pending: [UUID: Task<Void, any Error>] = [:]
    private var stopped = false

    public init(
        currentVersion: @escaping @MainActor () -> String?,
        prepare: @escaping @MainActor (String) async throws -> HostHerdrNotificationLease
    ) {
        self.currentVersion = currentVersion; self.prepare = prepare
    }

    public var pendingCount: Int { pending.count }

    public func receive(_ request: HostHerdrNotificationRequest) async throws {
        try Task.checkCancellation()
        guard !stopped, pending.count < 8, let version = currentVersion() else {
            throw HostWorkerError.rejected
        }
        let token = UUID()
        var prepared: HostHerdrNotificationLease?
        let task = Task {
            let lease = try await prepare(version)
            prepared = lease
            try Task.checkCancellation()
            guard !stopped, currentVersion() == version else { throw HostWorkerError.rejected }
            try await lease.apply(request, version: version)
            guard !stopped, currentVersion() == version else { throw HostWorkerError.rejected }
        }
        pending[token] = task
        let monitor = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                do {
                    guard let self, !self.stopped, self.currentVersion() == version else {
                        throw HostWorkerError.rejected
                    }
                    try prepared?.validate()
                } catch { task.cancel(); return }
            }
        }
        defer { monitor.cancel(); pending.removeValue(forKey: token) }
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    public func drain() async {
        for task in Array(pending.values) { _ = await task.result }
    }

    public func stop() {
        stopped = true
        for task in pending.values { task.cancel() }
    }
}
