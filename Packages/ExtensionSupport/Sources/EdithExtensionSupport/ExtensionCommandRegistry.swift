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

    public init() {}

    public func invoke(
        _ request: NSDictionary, completion: @escaping Completion, execute: @escaping Execute
    ) {
        guard let identifier = request["token"] as? String,
            let token = UUID(uuidString: identifier),
            let command = request["command"] as? String,
            let payload = request["payload"] as? Data,
            !command.isEmpty, command.utf8.count <= 256, !command.utf8.contains(0),
            payload.count <= ExtensionPeerEndpoint.maximumPayloadBytes,
            commands[token] == nil, commands.count < 8
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
        command.task.cancel()
        command.completion(nil, "The extension command was cancelled.")
    }

    public func shutdown() {
        let pending = commands.values
        commands.removeAll()
        for command in pending {
            command.task.cancel()
            command.completion(nil, "The extension was disabled.")
        }
    }

    private func finish(_ token: UUID, payload: Data?, message: String?) {
        guard let command = commands.removeValue(forKey: token) else { return }
        command.completion(payload as NSData?, message as NSString?)
    }
}
