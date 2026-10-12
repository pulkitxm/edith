import EdithExtensionSupport
import Foundation
import FunctionalActionContract

@MainActor
final class HostedFunctionalActionTransport: NSObject {
    struct Request {
        let token: UUID
        let operation: String
        let payload: Data
        let origin: String
        let activationID: UUID?
    }
    struct Invocation {
        let token: UUID
        let operation: String
        let payload: Data
        let response: Data
        let origin: String
        let activationID: UUID?
    }

    let context: HostedFunctionalActionContext
    let presentationID: UUID
    private let endpoint: ExtensionPeerEndpoint
    private let verifyCurrent: @MainActor () async throws -> Void
    private let observe: @MainActor (Invocation) async throws -> Void
    private let observeBeforeSend: @MainActor (Request) async throws -> Void
    private let readPersistentBeforeConstruction: @MainActor () async throws -> Data?
    private let observePersistentBefore: @MainActor (Data?) async throws -> Void
    private let validatePayload: @MainActor (String, Data) throws -> Void
    private var calls: [UUID: Task<Data, Error>] = [:]
    private var bridges: [UUID: Task<Void, Never>] = [:]
    private var completed: [Invocation] = []
    private var stopped = false
    private var started = 0
    private var activationID: UUID?
    private var baselineTask: Task<Data?, Error>?
    private var validations: [UUID: Task<Void, Error>] = [:]
    private var baselineCaptureStarted = false
    private var baselineCaptured = false
    private var persistentBaseline: Data?

    init(
        context: HostedFunctionalActionContext, presentationID: UUID,
        verifyCurrent: @escaping @MainActor () async throws -> Void,
        observe: @escaping @MainActor (Invocation) async throws -> Void,
        validatePayload: @escaping @MainActor (String, Data) throws -> Void,
        observeBeforeSend: @escaping @MainActor (Request) async throws -> Void,
        observePersistentBefore: @escaping @MainActor (Data?) async throws -> Void,
        readPersistentBeforeConstruction: @escaping @MainActor () async throws -> Data?
    ) throws {
        let commands = try context.ownedPath(named: "commands", kind: "directory")
        let expected = URL(fileURLWithPath: context.dataDirectory, isDirectory: true)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("ExtensionState/Commands", isDirectory: true)
        guard commands == expected else { throw HostedFunctionalActionError.invalid }
        self.context = context
        self.presentationID = presentationID
        self.verifyCurrent = verifyCurrent
        self.observe = observe
        self.validatePayload = validatePayload
        self.observeBeforeSend = observeBeforeSend
        self.observePersistentBefore = observePersistentBefore
        self.readPersistentBeforeConstruction = readPersistentBeforeConstruction
        endpoint = try ExtensionPeerEndpoint(
            namespace: context.hostIdentifier, owner: context.owner, directory: commands)
        super.init()
    }

    func makeEngineClient() throws -> ExtensionEngineClient {
        guard !stopped,
            let client = ExtensionEngineClient(bridge: self, presentationID: presentationID)
        else { throw HostedFunctionalActionError.invalid }
        return client
    }

    var originalInvocationCount: Int { completed.filter { $0.origin == "original-control" }.count }

    func beginActivation() throws -> UUID {
        guard !stopped, baselineCaptured, calls.isEmpty, bridges.isEmpty, activationID == nil else {
            throw HostedFunctionalActionError.invalid
        }
        let id = UUID()
        activationID = id
        return id
    }

    func endActivation(_ id: UUID) throws -> Invocation {
        guard !stopped, activationID == id, calls.isEmpty,
            let invocation = completed.last(where: {
                $0.activationID == id && $0.origin == "original-control"
                    && $0.operation == context.activationOperation
            })
        else { throw HostedFunctionalActionError.invalid }
        activationID = nil
        return invocation
    }

    func invokeOriginal(_ operation: String, payload: Data) async throws -> Data {
        try await invoke(operation, payload: payload, token: UUID(), origin: "original-control")
    }

    func readAuthoritative(_ operation: String, payload: Data = Data("{}".utf8)) async throws
        -> Data
    {
        try await invoke(
            operation, payload: payload, token: UUID(), origin: "authoritative-readback")
    }

    func waitForOriginalInvocation(_ operation: String, after count: Int) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            guard !stopped else { throw HostedFunctionalActionError.invalid }
            if completed.filter({ $0.origin == "original-control" }).dropFirst(count)
                .contains(where: { $0.operation == operation })
            {
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw ExtensionPeerError.timedOut
    }

    func requireCurrent() async throws {
        guard !stopped else { throw HostedFunctionalActionError.invalid }
        guard validations.count < 8 else { throw HostedFunctionalActionError.invalid }
        let id = UUID()
        let task = Task { [self] in
            try requireRunning()
            try await verifyCurrent()
            try requireRunning()
        }
        validations[id] = task
        defer { validations[id] = nil }
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
        try requireRunning()
    }

    func capturePersistentBeforeConstruction() async throws -> Data? {
        try requireRunning()
        guard started == 0, calls.isEmpty, bridges.isEmpty, activationID == nil else {
            throw HostedFunctionalActionError.invalid
        }
        if baselineCaptured { return persistentBaseline }
        guard !baselineCaptureStarted else { throw HostedFunctionalActionError.invalid }
        baselineCaptureStarted = true
        let task = Task { [self] in try await captureBaseline() }
        baselineTask = task
        defer { baselineTask = nil }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func captureBaseline() async throws -> Data? {
        try requireRunning()
        try await verifyCurrent()
        try requireRunning()
        let value = try await readPersistentBeforeConstruction()
        try requireRunning()
        guard value.map({ !$0.isEmpty && $0.count <= 1_048_576 }) ?? true else {
            throw HostedFunctionalActionError.invalid
        }
        try await verifyCurrent()
        try requireRunning()
        try await observePersistentBefore(value)
        try requireRunning()
        persistentBaseline = value
        baselineCaptured = true
        return value
    }

    func shutdown() async {
        stopped = true
        activationID = nil
        let pending = Array(calls.values)
        let callbacks = Array(bridges.values)
        let checks = Array(validations.values)
        let baseline = baselineTask
        baseline?.cancel()
        checks.forEach { $0.cancel() }
        pending.forEach { $0.cancel() }
        callbacks.forEach { $0.cancel() }
        _ = await baseline?.result
        for task in checks { _ = await task.result }
        for task in pending { _ = await task.result }
        for task in callbacks { await task.value }
        calls.removeAll()
        bridges.removeAll()
        validations.removeAll()
    }

    @objc(invoke:completion:)
    func invoke(_ data: NSData, completion: @escaping @Sendable (NSData) -> Void) {
        do {
            let object = try HostedFunctionalJSON.object(data as Data)
            guard
                Set(object.keys) == ["token", "presentationID", "operation", "payload", "timeout"]
            else { throw HostedFunctionalActionError.invalid }
            let request = try JSONDecoder().decode(ExtensionEngineRequest.self, from: data as Data)
            try request.validate()
            guard request.presentationID == presentationID, !stopped,
                calls.count + bridges.count < 8,
                calls[request.token] == nil, bridges[request.token] == nil
            else { throw HostedFunctionalActionError.invalid }
            bridges[request.token] = Task { [self] in
                defer { bridges[request.token] = nil }
                do {
                    let response = try await invoke(
                        request.operation, payload: request.payload, token: request.token,
                        origin: "original-control", timeout: request.timeout)
                    try requireRunning()
                    completion(
                        try ExtensionEngineWire.encode(
                            ExtensionEngineReply(token: request.token, ok: true, payload: response))
                            as NSData)
                } catch {
                    let reply = ExtensionEngineReply(token: request.token, ok: false)
                    if let bytes = try? ExtensionEngineWire.encode(reply) {
                        completion(bytes as NSData)
                    }
                }
            }
        } catch {
            completion(Data("{}".utf8) as NSData)
        }
    }

    @objc(cancel:)
    func cancel(_ token: NSString) {
        guard let id = UUID(uuidString: token as String) else { return }
        calls[id]?.cancel()
        bridges[id]?.cancel()
    }

    private func invoke(
        _ operation: String, payload: Data, token: UUID, origin: String, timeout: Double = 10
    ) async throws -> Data {
        try requireRunning()
        guard baselineCaptured else { throw HostedFunctionalActionError.invalid }
        try context.requireOperation(operation)
        _ = try HostedFunctionalJSON.object(payload)
        try validatePayload(operation, payload)
        guard calls.count < 8, calls[token] == nil, started < 128,
            timeout.isFinite, timeout > 0, timeout <= 30
        else { throw HostedFunctionalActionError.invalid }
        started += 1
        let activation = activationID
        let task = Task { [self] in
            try await perform(
                operation, payload: payload, token: token, origin: origin,
                activation: activation, timeout: timeout)
        }
        calls[token] = task
        defer { calls[token] = nil }
        let response = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
        try requireRunning()
        return response
    }

    private func perform(
        _ operation: String, payload: Data, token: UUID, origin: String,
        activation: UUID?, timeout: Double
    ) async throws -> Data {
        try requireRunning()
        try await verifyCurrent()
        try requireRunning()
        try await observeBeforeSend(
            Request(
                token: token, operation: operation, payload: payload,
                origin: origin, activationID: activation))
        try requireRunning()
        try await verifyCurrent()
        try requireRunning()
        let response = try await endpoint.invoke(operation, payload: payload, timeout: timeout)
        try requireRunning()
        try await verifyCurrent()
        try requireRunning()
        guard !stopped, response.count <= 1_048_576 else {
            throw HostedFunctionalActionError.invalid
        }
        let invocation = Invocation(
            token: token, operation: operation, payload: payload, response: response,
            origin: origin,
            activationID: activation
        )
        try await observe(invocation)
        try requireRunning()
        completed.append(invocation)
        return response
    }

    private func requireRunning() throws {
        try Task.checkCancellation()
        guard !stopped else { throw HostedFunctionalActionError.invalid }
    }
}

@MainActor
enum HostedFunctionalActionNativeDriver {
    static func run<Case: HostedFunctionalActionCase>(
        context: HostedFunctionalActionContext,
        transport: HostedFunctionalActionTransport,
        makeCase: @MainActor () throws -> Case
    ) async throws -> (authoritative: Data, persistent: Data?) {
        guard context.owner != "calendar", Case.owner == context.owner,
            transport.context == context,
            Case.activationOperation == context.activationOperation
        else {
            throw HostedFunctionalActionError.invalid
        }
        let before: Data?
        do {
            try await transport.requireCurrent()
            before = try await transport.capturePersistentBeforeConstruction()
        } catch {
            await transport.shutdown()
            throw error
        }
        let action: Case
        do { action = try makeCase() } catch { await transport.shutdown(); throw error }
        do {
            let activation = try transport.beginActivation()
            try await action.activateOriginalControl(context: context)
            _ = try transport.endActivation(activation)
            try await transport.requireCurrent()
            let authoritative = try await action.readAuthoritativeState(context: context)
            guard !authoritative.isEmpty, authoritative.count <= 1_048_576 else {
                throw HostedFunctionalActionError.invalid
            }
            let persistent = try await action.readPersistentState(context: context)
            if context.phase != "initial" {
                guard before == persistent else { throw HostedFunctionalActionError.invalid }
            }
            try await transport.requireCurrent()
            await action.shutdownPresentation()
            await transport.shutdown()
            return (authoritative, persistent)
        } catch {
            await action.shutdownPresentation()
            await transport.shutdown()
            throw error
        }
    }
}
