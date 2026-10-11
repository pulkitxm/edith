import Foundation

@MainActor
public final class ExtensionCommandRegistry {
    #if EDITH_FUNCTIONAL_FIXTURE
    public static let ownerJoinedNotification = Notification.Name(
        "edith.extension.command.owner-joined")
    private var witnessedRetirements = Set<UUID>()
    private(set) var pendingJoins = 0
    #endif
    public typealias Completion = (NSData?, NSString?) -> Void
    public typealias Execute = @MainActor @Sendable (String, Data) async throws -> Data
    private struct Command {
        let task: Task<Void, Never>
        let completion: Completion
    }
    private var commands: [UUID: Command] = [:]
    private struct Owner {
        let identity: UUID
        let task: Task<Void, Never>
    }
    private var retired: [UUID: Task<Void, Never>] = [:]
    private var running: [UUID: Owner] = [:]
    private var stopping = false
    private var suspension: UUID?

    public init() {}

    public func invoke(
        _ request: NSDictionary, completion: @escaping Completion, execute: @escaping Execute
    ) {
        guard !stopping, suspension == nil, let identifier = request["token"] as? String,
            let token = UUID(uuidString: identifier),
            let command = request["command"] as? String,
            let payload = request["payload"] as? Data,
            !command.isEmpty, command.utf8.count <= 256, !command.utf8.contains(0),
            payload.count <= ExtensionPeerEndpoint.maximumPayloadBytes,
            commands[token] == nil, retired[token] == nil, running[token] == nil, running.count < 8
        else { completion(nil, "The extension command is invalid."); return }
        let task = Task { [weak self] in
            do {
                let result = try await execute(command, payload)
                try Task.checkCancellation()
                guard result.count <= ExtensionPeerEndpoint.maximumPayloadBytes else {
                    throw ExtensionPeerError.invalidRequest
                }
                self?.finish(token, payload: result, message: nil)
            } catch { self?.finish(token, payload: nil, message: error.localizedDescription) }
        }
        let identity = UUID()
        commands[token] = Command(task: task, completion: completion)
        running[token] = Owner(identity: identity, task: task)
        Task { [self] in
            await task.value
            retire(token, identity: identity)
        }
    }

    public func cancel(_ identifier: String) {
        guard let token = UUID(uuidString: identifier),
            let command = commands.removeValue(forKey: token)
        else { return }
        retired[token] = command.task
        command.task.cancel()
        command.completion(nil, "The extension command was cancelled.")
    }

    @discardableResult
    public func closeAdmission() -> UUID {
        let token = suspension ?? UUID()
        suspension = token
        return token
    }

    @discardableResult
    public func closeAdmissionAndWait() async -> UUID {
        let token = closeAdmission()
        await joinRunning()
        return token
    }

    @discardableResult
    public func suspend() -> UUID {
        let token = closeAdmission()
        cancelAll(message: "The extension is preparing to stop.")
        return token
    }

    @discardableResult
    public func suspendAndWait() async -> UUID {
        let token = suspend()
        await joinRunning()
        return token
    }

    public func resume(_ token: UUID) -> Bool {
        guard !stopping, suspension == token, commands.isEmpty, retired.isEmpty, running.isEmpty
        else {
            return false
        }
        suspension = nil
        return true
    }

    public func shutdown() {
        stopping = true
        cancelAll(message: "The extension was disabled.")
    }

    public func shutdownAndWait() async {
        shutdown()
        await joinRunning()
    }

    private func cancelAll(message: NSString) {
        let pending = commands
        commands.removeAll()
        for (token, command) in pending {
            retired[token] = command.task
            command.task.cancel()
            command.completion(nil, message)
        }
    }

    private func joinRunning() async {
        let pending = Array(running)
        #if EDITH_FUNCTIONAL_FIXTURE
        pendingJoins += pending.count
        defer { pendingJoins -= pending.count }
        #endif
        for (token, owner) in pending {
            await owner.task.value
            retire(token, identity: owner.identity)
            #if EDITH_FUNCTIONAL_FIXTURE
            if witnessedRetirements.insert(token).inserted {
                NotificationCenter.default.post(
                    name: Self.ownerJoinedNotification, object: self,
                    userInfo: ["token": token.uuidString])
            }
            #endif
        }
    }

    private func retire(_ token: UUID, identity: UUID) {
        guard running[token]?.identity == identity else { return }
        running[token] = nil
        retired[token] = nil
    }

    private func finish(_ token: UUID, payload: Data?, message: String?) {
        guard let command = commands.removeValue(forKey: token) else { return }
        command.completion(payload as NSData?, message as NSString?)
    }
}
