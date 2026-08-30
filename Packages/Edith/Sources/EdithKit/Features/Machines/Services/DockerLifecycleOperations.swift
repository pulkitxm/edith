import EdithCore
import Foundation

public enum DockerLifecycleOperation: String, CaseIterable, Equatable, Sendable {
    case start
    case stop
    case restart
    case removeContainer
    case removeImage
    case removeVolume
    case prune

    public var descriptor: UserOperationDescriptor {
        UserOperationDescriptor(
            id: UserOperationID(rawValue: "machines.docker.\(identifier)"), summary: summary,
            cli: ["machines", "docker", cliVerb], effect: effect,
            requiresPreview: effect == .destructive)
    }

    public var cliVerb: String {
        switch self {
        case .start: "start"
        case .stop: "stop"
        case .restart: "restart"
        case .removeContainer: "rm"
        case .removeImage: "rmi"
        case .removeVolume: "volume-rm"
        case .prune: "prune"
        }
    }

    public init?(cliVerb: String) {
        guard let operation = Self.allCases.first(where: { $0.cliVerb == cliVerb }) else {
            return nil
        }
        self = operation
    }

    private var identifier: String {
        switch self {
        case .removeContainer: "container.remove"
        case .removeImage: "image.remove"
        case .removeVolume: "volume.remove"
        default: cliVerb
        }
    }

    private var summary: String {
        switch self {
        case .start: "Start one or more containers."
        case .stop: "Stop one or more containers."
        case .restart: "Restart one or more containers."
        case .removeContainer: "Remove one or more containers."
        case .removeImage: "Remove a container image."
        case .removeVolume: "Remove a container volume."
        case .prune: "Remove unused container runtime objects."
        }
    }

    private var effect: UserOperationEffect {
        switch self {
        case .start, .stop, .restart: .write
        case .removeContainer, .removeImage, .removeVolume, .prune: .destructive
        }
    }
}

public enum DockerPruneTarget: String, CaseIterable, Equatable, Sendable {
    case images
    case volumes
    case networks
    case builder
    case system
}

public enum DockerLifecycleTarget: Equatable, Sendable {
    case containers([String])
    case image(String, force: Bool)
    case volume(String)
    case prune(DockerPruneTarget)
}

public struct DockerLifecycleOperationResult: Equatable, Sendable {
    public let operation: DockerLifecycleOperation
    public let target: DockerLifecycleTarget
    public let command: String
    public let output: String

    public init(
        operation: DockerLifecycleOperation, target: DockerLifecycleTarget, command: String,
        output: String
    ) {
        self.operation = operation
        self.target = target
        self.command = command
        self.output = output
    }
}

public enum DockerLifecycleOperationError: LocalizedError, Equatable, Sendable {
    case missingContainer
    case invalidTarget(DockerLifecycleOperation, DockerLifecycleTarget)

    public var errorDescription: String? {
        switch self {
        case .missingContainer: "Name at least one container."
        case let .invalidTarget(operation, _):
            "The target does not match docker \(operation.cliVerb)."
        }
    }
}

public enum DockerLifecycleOperationExecution {
    public typealias Run = (String, TimeInterval) async -> Result<String, Error>

    public static func command(
        _ operation: DockerLifecycleOperation, target: DockerLifecycleTarget,
        platform: RemoteMachinePlatform = .linux
    ) throws -> (command: String, timeout: TimeInterval) {
        switch (operation, target) {
        case let (.start, .containers(ids)), let (.stop, .containers(ids)),
            let (.restart, .containers(ids)), let (.removeContainer, .containers(ids)):
            guard !ids.isEmpty else { throw DockerLifecycleOperationError.missingContainer }
            return (
                DockerCommands.lifecycle(operation.cliVerb, ids: ids, platform: platform), 120
            )
        case let (.removeImage, .image(reference, force)):
            return (DockerCommands.removeImage(reference, force: force, platform: platform), 120)
        case let (.removeVolume, .volume(name)):
            return (DockerCommands.removeVolume(name, platform: platform), 120)
        case let (.prune, .prune(target)):
            return (DockerCommands.prune(target.rawValue, platform: platform), 300)
        default:
            throw DockerLifecycleOperationError.invalidTarget(operation, target)
        }
    }

    public static func perform(
        _ operation: DockerLifecycleOperation, target: DockerLifecycleTarget,
        platform: RemoteMachinePlatform = .linux, using run: Run
    ) async -> Result<DockerLifecycleOperationResult, Error> {
        let request: (command: String, timeout: TimeInterval)
        do {
            request = try command(operation, target: target, platform: platform)
        } catch {
            return .failure(error)
        }
        switch await run(request.command, request.timeout) {
        case let .success(output):
            return .success(
                DockerLifecycleOperationResult(
                    operation: operation, target: target, command: request.command, output: output))
        case let .failure(error):
            return .failure(error)
        }
    }
}
