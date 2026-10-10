import Foundation

@MainActor
public final class ExtensionCommandRegistry {
    public typealias Completion = (NSData?, NSString?) -> Void
    public typealias Execute = @MainActor @Sendable (String, Data) async throws -> Data
    private struct Command {
        let task: Task<Void, Never>
        let completion: Completion
    }
    private var commands: [UUID: Command] = [:]
    private var retired: [UUID: Task<Void, Never>] = [:]
    private var stopping = false

    public init() {}

    public func invoke(
        _ request: NSDictionary, completion: @escaping Completion, execute: @escaping Execute
    ) {
        guard !stopping, let identifier = request["token"] as? String,
            let token = UUID(uuidString: identifier),
            let command = request["command"] as? String,
            let payload = request["payload"] as? Data,
            !command.isEmpty, command.utf8.count <= 256, !command.utf8.contains(0),
            payload.count <= ExtensionPeerEndpoint.maximumPayloadBytes,
            commands[token] == nil, retired[token] == nil, commands.count + retired.count < 8
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
        commands[token] = Command(task: task, completion: completion)
    }

    public func cancel(_ identifier: String) {
        guard let token = UUID(uuidString: identifier),
            let command = commands.removeValue(forKey: token)
        else { return }
        retired[token] = command.task
        command.task.cancel()
        command.completion(nil, "The extension command was cancelled.")
    }

    public func shutdown() {
        stopping = true
        let pending = commands
        commands.removeAll()
        for (token, command) in pending {
            retired[token] = command.task
            command.task.cancel()
            command.completion(nil, "The extension was disabled.")
        }
    }

    public func shutdownAndWait() async {
        shutdown()
        let pending = Array(retired.values)
        for task in pending { await task.value }
    }

    private func finish(_ token: UUID, payload: Data?, message: String?) {
        retired.removeValue(forKey: token)
        guard let command = commands.removeValue(forKey: token) else { return }
        command.completion(payload as NSData?, message as NSString?)
    }
}
