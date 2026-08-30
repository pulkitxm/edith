import EdithCore
import Foundation

public enum MachineForwardOperation: String, CaseIterable, Sendable {
    case add
    case remove
    case enable
    case disable

    public var descriptor: UserOperationDescriptor {
        switch self {
        case .add:
            descriptor("add", "Save a port forward.")
        case .remove:
            descriptor("rm", "Remove a saved port forward.")
        case .enable:
            descriptor("on", "Open a saved port forward.")
        case .disable:
            descriptor("off", "Close a saved port forward.")
        }
    }

    private func descriptor(_ verb: String, _ summary: String) -> UserOperationDescriptor {
        UserOperationDescriptor(
            id: UserOperationID(rawValue: "machines.forwards.\(rawValue)"), summary: summary,
            cli: ["machines", "forwards", verb], effect: .write)
    }
}

public struct MachineForwardOperationResult: Equatable, Sendable {
    public let operation: MachineForwardOperation
    public let forward: PortForward
    public let active: Bool?

    public init(operation: MachineForwardOperation, forward: PortForward, active: Bool?) {
        self.operation = operation
        self.forward = forward
        self.active = active
    }
}

public enum MachineForwardOperationError: LocalizedError, Equatable, Sendable {
    case invalidPort(Int)
    case duplicateLocalPort(Int)
    case liveConnectionUnavailable
    case liveActionFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidPort(port):
            return "Port \(port) must be between 1 and 65535."
        case let .duplicateLocalPort(port):
            return "Local port \(port) already has a saved forward."
        case .liveConnectionUnavailable:
            return "The shared connection is unavailable."
        case let .liveActionFailed(message):
            return message
        }
    }
}

public enum MachineForwardOperationExecution {
    public typealias PersistAdd = (PortForward) -> Void
    public typealias PersistRemove = (UUID) -> Void
    public typealias SetActive = (PortForward, Bool) async -> String?

    public static func perform(
        _ operation: MachineForwardOperation, forward: PortForward,
        existing: [PortForward] = [],
        persistAdd: PersistAdd = { _ = MachineRegistry.addForward($0) },
        persistRemove: PersistRemove = { _ = MachineRegistry.removeForward(id: $0) },
        setActive: SetActive? = nil, notify: () -> Void = {}
    ) async -> Result<MachineForwardOperationResult, Error> {
        guard (1...65535).contains(forward.localPort) else {
            return .failure(MachineForwardOperationError.invalidPort(forward.localPort))
        }
        guard (1...65535).contains(forward.remotePort) else {
            return .failure(MachineForwardOperationError.invalidPort(forward.remotePort))
        }
        switch operation {
        case .add:
            guard
                !existing.contains(where: {
                    $0.machineID == forward.machineID && $0.localPort == forward.localPort
                        && $0.id != forward.id
                })
            else {
                return .failure(
                    MachineForwardOperationError.duplicateLocalPort(forward.localPort))
            }
            persistAdd(forward)
            notify()
            return .success(
                MachineForwardOperationResult(operation: operation, forward: forward, active: nil))
        case .remove:
            if let setActive, let failure = await setActive(forward, false) {
                return .failure(MachineForwardOperationError.liveActionFailed(failure))
            }
            persistRemove(forward.id)
            notify()
            return .success(
                MachineForwardOperationResult(operation: operation, forward: forward, active: nil))
        case .enable, .disable:
            guard let setActive else {
                return .failure(MachineForwardOperationError.liveConnectionUnavailable)
            }
            let active = operation == .enable
            if let failure = await setActive(forward, active) {
                return .failure(MachineForwardOperationError.liveActionFailed(failure))
            }
            return .success(
                MachineForwardOperationResult(
                    operation: operation, forward: forward, active: active))
        }
    }
}

public enum MachineSnippetOperation: String, CaseIterable, Sendable {
    case add
    case remove

    public var descriptor: UserOperationDescriptor {
        let verb = self == .add ? "add" : "rm"
        return UserOperationDescriptor(
            id: UserOperationID(rawValue: "machines.snippets.\(rawValue)"),
            summary: self == .add ? "Save a command snippet." : "Remove a command snippet.",
            cli: ["machines", "snippets", verb], effect: .write)
    }
}

public struct MachineSnippetOperationResult: Equatable, Sendable {
    public let operation: MachineSnippetOperation
    public let snippet: CommandSnippet

    public init(operation: MachineSnippetOperation, snippet: CommandSnippet) {
        self.operation = operation
        self.snippet = snippet
    }
}

public enum MachineSnippetOperationError: LocalizedError, Equatable, Sendable {
    case missingTitle
    case missingCommand

    public var errorDescription: String? {
        switch self {
        case .missingTitle:
            return "A snippet needs a name."
        case .missingCommand:
            return "A snippet needs a command to run."
        }
    }
}

public enum MachineSnippetOperationExecution {
    public typealias PersistAdd = (CommandSnippet) -> Void
    public typealias PersistRemove = (UUID) -> Void

    public static func perform(
        _ operation: MachineSnippetOperation, snippet: CommandSnippet,
        persistAdd: PersistAdd = { _ = MachineRegistry.addSnippet($0) },
        persistRemove: PersistRemove = { _ = MachineRegistry.removeSnippet(id: $0) },
        notify: () -> Void = {}
    ) -> Result<MachineSnippetOperationResult, Error> {
        let title = snippet.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let command = snippet.command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard operation != .add || !title.isEmpty else {
            return .failure(MachineSnippetOperationError.missingTitle)
        }
        guard operation != .add || !command.isEmpty else {
            return .failure(MachineSnippetOperationError.missingCommand)
        }
        switch operation {
        case .add:
            persistAdd(snippet)
        case .remove:
            persistRemove(snippet.id)
        }
        notify()
        return .success(MachineSnippetOperationResult(operation: operation, snippet: snippet))
    }
}

public enum MachineServiceOperation: String, CaseIterable, Sendable {
    case start
    case stop
    case restart

    public var descriptor: UserOperationDescriptor {
        UserOperationDescriptor(
            id: UserOperationID(rawValue: "machines.services.\(rawValue)"),
            summary: "\(rawValue.capitalized) a systemd unit.",
            cli: ["machines", "services", rawValue], effect: .write)
    }
}

public struct MachineServiceOperationResult: Equatable, Sendable {
    public let operation: MachineServiceOperation
    public let unit: String
    public let output: String

    public init(operation: MachineServiceOperation, unit: String, output: String) {
        self.operation = operation
        self.unit = unit
        self.output = output
    }
}

public enum MachineServiceOperationError: LocalizedError, Equatable, Sendable {
    case missingUnit

    public var errorDescription: String? { "A systemd unit name is required." }
}

public enum MachineServiceOperationExecution {
    public typealias Run = (String, Data?, TimeInterval) async -> Result<String, Error>

    public static func command(
        _ operation: MachineServiceOperation, unit: String, hasSudoPassword: Bool,
        platform: RemoteMachinePlatform = .linux
    ) -> String {
        ServiceCommands.action(
            operation.rawValue, unit: unit, withSudoPassword: hasSudoPassword,
            platform: platform)
    }

    public static func perform(
        _ operation: MachineServiceOperation, unit: String, sudoPassword: Data?,
        platform: RemoteMachinePlatform = .linux, using run: Run
    ) async -> Result<MachineServiceOperationResult, Error> {
        let trimmed = unit.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .failure(MachineServiceOperationError.missingUnit)
        }
        let command = command(
            operation, unit: trimmed, hasSudoPassword: sudoPassword != nil,
            platform: platform)
        switch await run(command, platform == .windows ? nil : sudoPassword, 60) {
        case let .success(output):
            return .success(
                MachineServiceOperationResult(
                    operation: operation, unit: trimmed, output: output))
        case let .failure(error):
            return .failure(error)
        }
    }
}

public enum MachineProcessOperation: String, CaseIterable, Sendable {
    case terminate

    public var descriptor: UserOperationDescriptor {
        UserOperationDescriptor(
            id: UserOperationID(rawValue: "machines.process.terminate"),
            summary: "Send a signal to a process.", cli: ["machines", "kill"],
            effect: .destructive, requiresPreview: true)
    }
}

public struct MachineProcessOperationResult: Equatable, Sendable {
    public let pid: Int
    public let signal: String
    public let alreadyExited: Bool

    public init(pid: Int, signal: String, alreadyExited: Bool) {
        self.pid = pid
        self.signal = signal
        self.alreadyExited = alreadyExited
    }
}

public enum MachineProcessOperationError: LocalizedError, Equatable, Sendable {
    case invalidPID(Int)
    case invalidSignal(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidPID(pid):
            return "Process id \(pid) must be greater than zero."
        case let .invalidSignal(signal):
            return "There is no signal called \(signal)."
        }
    }
}

public enum MachineProcessOperationExecution {
    public typealias Run = (String, TimeInterval) async -> Result<String, Error>

    public static func perform(
        pid: Int, signal: String, platform: RemoteMachinePlatform = .linux,
        using run: Run
    ) async -> Result<MachineProcessOperationResult, Error> {
        guard pid > 0 else {
            return .failure(MachineProcessOperationError.invalidPID(pid))
        }
        guard let normalized = ProcessCommands.normalizedSignal(signal) else {
            return .failure(MachineProcessOperationError.invalidSignal(signal))
        }
        switch await run(
            ProcessCommands.kill(pid: pid, signal: normalized, platform: platform), 30
        ) {
        case let .success(output):
            return .success(
                MachineProcessOperationResult(
                    pid: pid, signal: normalized,
                    alreadyExited: ProcessCommands.hadAlreadyExited(output)))
        case let .failure(error):
            return .failure(error)
        }
    }
}

public enum MachineDockerPauseOperation: String, CaseIterable, Sendable {
    case pause
    case unpause

    public var descriptor: UserOperationDescriptor {
        UserOperationDescriptor(
            id: UserOperationID(rawValue: "machines.docker.\(rawValue)"),
            summary: self == .pause ? "Pause container processes." : "Resume container processes.",
            cli: ["machines", "docker", rawValue], effect: .write)
    }
}

public struct MachineDockerPauseOperationResult: Equatable, Sendable {
    public let operation: MachineDockerPauseOperation
    public let containerIDs: [String]

    public init(operation: MachineDockerPauseOperation, containerIDs: [String]) {
        self.operation = operation
        self.containerIDs = containerIDs
    }
}

public enum MachineDockerPauseOperationError: LocalizedError, Equatable, Sendable {
    case missingContainer

    public var errorDescription: String? { "Name at least one container." }
}

public enum MachineDockerPauseOperationExecution {
    public typealias Run = (String, TimeInterval) async -> Result<String, Error>

    public static func perform(
        _ operation: MachineDockerPauseOperation, containerIDs: [String],
        platform: RemoteMachinePlatform = .linux, using run: Run
    ) async -> Result<MachineDockerPauseOperationResult, Error> {
        guard !containerIDs.isEmpty else {
            return .failure(MachineDockerPauseOperationError.missingContainer)
        }
        switch await run(
            DockerCommands.lifecycle(
                operation.rawValue, ids: containerIDs, platform: platform), 120)
        {
        case .success:
            return .success(
                MachineDockerPauseOperationResult(
                    operation: operation, containerIDs: containerIDs))
        case let .failure(error):
            return .failure(error)
        }
    }
}
