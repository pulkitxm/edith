import EdithExtensionSupport
import Foundation
import FunctionalActionContract

@MainActor
final class HostedFunctionalActionTransport: NSObject {
    struct Invocation {
        let token: UUID
        let operation: String
        let payload: Data
        let response: Data
        let origin: String
    }

    let context: HostedFunctionalActionContext
    let presentationID: UUID
    private let endpoint: ExtensionPeerEndpoint
    private let verifyCurrent: @MainActor () async throws -> Void
    private let observe: @MainActor (Invocation) async throws -> Void
    private var calls: [UUID: Task<Void, Never>] = [:]
    private var completed: [Invocation] = []
    private var stopped = false

    init(
        context: HostedFunctionalActionContext, presentationID: UUID,
        verifyCurrent: @escaping @MainActor () async throws -> Void,
        observe: @escaping @MainActor (Invocation) async throws -> Void
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

    var originalActionAcknowledged: Bool {
        completed.contains {
            $0.origin == "original-control" && $0.operation == context.activationOperation
        }
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
        try await verifyCurrent()
    }

    func shutdown() async {
        stopped = true
        let pending = Array(calls.values)
        pending.forEach { $0.cancel() }
        for task in pending { await task.value }
        calls.removeAll()
    }

    @objc(invoke:completion:)
    func invoke(_ data: NSData, completion: @escaping @Sendable (NSData) -> Void) {
        do {
            let request = try ExtensionEngineWire.decode(
                ExtensionEngineRequest.self, from: data as Data)
            try request.validate()
            guard request.presentationID == presentationID, !stopped, calls.count < 8,
                calls[request.token] == nil
            else { throw HostedFunctionalActionError.invalid }
            calls[request.token] = Task { [self] in
                defer { calls[request.token] = nil }
                do {
                    let response = try await invoke(
                        request.operation, payload: request.payload, token: request.token,
                        origin: "original-control", timeout: request.timeout)
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
    }

    private func invoke(
        _ operation: String, payload: Data, token: UUID, origin: String, timeout: Double = 10
    ) async throws -> Data {
        try Task.checkCancellation()
        try context.requireOperation(operation)
        guard !stopped, completed.count < 128, payload.count <= 1_048_576,
            (try? JSONSerialization.jsonObject(with: payload, options: .fragmentsAllowed)) != nil,
            timeout.isFinite, timeout > 0, timeout <= 30
        else { throw HostedFunctionalActionError.invalid }
        try await verifyCurrent()
        let response = try await endpoint.invoke(operation, payload: payload, timeout: timeout)
        try Task.checkCancellation()
        try await verifyCurrent()
        guard !stopped, response.count <= 1_048_576 else {
            throw HostedFunctionalActionError.invalid
        }
        let invocation = Invocation(
            token: token, operation: operation, payload: payload, response: response, origin: origin
        )
        try await observe(invocation)
        completed.append(invocation)
        return response
    }
}

@MainActor
enum HostedFunctionalActionNativeDriver {
    static func run<Case: HostedFunctionalActionCase>(
        context: HostedFunctionalActionContext,
        transport: HostedFunctionalActionTransport,
        makeCase: @MainActor () throws -> Case
    ) async throws -> (authoritative: Data, persistent: Data?) {
        guard Case.owner == context.owner, transport.context == context,
            Case.activationOperation == context.activationOperation
        else {
            throw HostedFunctionalActionError.invalid
        }
        try await transport.requireCurrent()
        let action = try makeCase()
        do {
            let before =
                context.phase == "initial"
                ? nil : try await action.readPersistentState(context: context)
            try await action.activateOriginalControl(context: context)
            guard transport.originalActionAcknowledged else {
                throw HostedFunctionalActionError.invalid
            }
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
