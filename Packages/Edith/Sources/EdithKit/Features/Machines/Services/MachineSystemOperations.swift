import EdithCore
import Foundation

public enum MachineThermalOperation: String, CaseIterable, Equatable, Sendable {
    case status
    case set

    public var descriptor: UserOperationDescriptor {
        switch self {
        case .status:
            descriptor("status", "Read the active and available thermal profiles.", effect: .read)
        case .set:
            descriptor("set", "Switch the active thermal profile.", effect: .write)
        }
    }

    private func descriptor(
        _ verb: String, _ summary: String, effect: UserOperationEffect
    ) -> UserOperationDescriptor {
        UserOperationDescriptor(
            id: UserOperationID(rawValue: "machines.thermal.\(rawValue)"), summary: summary,
            cli: ["machines", "thermal", verb], effect: effect)
    }
}

public enum MachineThermalOperationError: LocalizedError, Equatable, Sendable {
    case unavailable
    case invalidProfile(String)
    case invalidDuration(Int)

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            "Platform thermal profiles are unavailable."
        case let .invalidProfile(profile):
            "\(profile) is not a valid thermal profile."
        case let .invalidDuration(seconds):
            "A thermal profile duration cannot be \(seconds) seconds."
        }
    }
}

public struct MachineThermalSetResult: Equatable, Sendable {
    public let profile: String
    public let durationSeconds: Int
    public let output: String

    public init(profile: String, durationSeconds: Int, output: String) {
        self.profile = profile
        self.durationSeconds = durationSeconds
        self.output = output
    }
}

public enum MachineThermalOperationExecution {
    public typealias Run = (String, Data?, TimeInterval) async -> Result<String, Error>
    public typealias SudoPasswordLookup = (UUID) -> Data?

    public static func status(
        timeout: TimeInterval = 15, platform: RemoteMachinePlatform = .linux, using run: Run
    ) async -> Result<MachinePlatformProfile, Error> {
        let command =
            platform == .windows
            ? WindowsPowerProfileCommands.status : MachineThermalControls.statusCommand
        switch await run(command, nil, timeout) {
        case let .success(output):
            let profile =
                platform == .windows
                ? WindowsPowerProfileCommands.parseStatus(output)
                : MachineThermalControls.parseStatus(output)
            guard let profile else {
                return .failure(MachineThermalOperationError.unavailable)
            }
            return .success(profile)
        case let .failure(error):
            return .failure(error)
        }
    }

    public static func set(
        profile: String, durationSeconds: Int, machineID: UUID,
        platform: RemoteMachinePlatform = .linux,
        sudoPassword: SudoPasswordLookup = { SudoPassword.stdin(machineID: $0) },
        using run: Run
    ) async -> Result<MachineThermalSetResult, Error> {
        guard (0...604_800).contains(durationSeconds) else {
            return .failure(MachineThermalOperationError.invalidDuration(durationSeconds))
        }
        let stdin = platform == .windows ? nil : sudoPassword(machineID)
        let command =
            platform == .windows
            ? WindowsPowerProfileCommands.setProfile(
                profile, durationSeconds: durationSeconds)
            : MachineThermalControls.setProfile(
                profile, durationSeconds: durationSeconds, withSudoPassword: stdin != nil)
        guard let command else {
            return .failure(MachineThermalOperationError.invalidProfile(profile))
        }
        switch await run(command, stdin, 30) {
        case let .success(output):
            return .success(
                MachineThermalSetResult(
                    profile: profile, durationSeconds: durationSeconds, output: output))
        case let .failure(error):
            return .failure(error)
        }
    }
}

public enum MachineExecOperation: String, CaseIterable, Equatable, Sendable {
    case dockerShell

    public var descriptor: UserOperationDescriptor {
        UserOperationDescriptor(
            id: UserOperationID(rawValue: "machines.exec.docker-shell"),
            summary: "Open an interactive shell in a Docker container.",
            cli: ["machines", "docker", "shell"], effect: .interactive)
    }
}

public struct MachineDockerShellLaunch: Equatable, Sendable {
    public let executable: String
    public let arguments: [String]
    public let environment: [String]

    public init(executable: String, arguments: [String], environment: [String]) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
    }
}

public enum MachineExecOperationExecution {
    public static func dockerShellCommand(
        containerID: String, platform: RemoteMachinePlatform = .linux
    ) -> String {
        DockerCommands.execShell(containerID: containerID, platform: platform)
    }

    public static func dockerShellLaunch(
        containerID: String, connection: SSHConnection, environment: [String]
    ) -> MachineDockerShellLaunch {
        let command = dockerShellCommand(containerID: containerID)
        return MachineDockerShellLaunch(
            executable: SSHConnection.executable.path,
            arguments: connection.terminalArguments(remoteCommand: command),
            environment: environment + connection.terminalEnvironment())
    }

    public static func interactiveCommand(
        words: [String], workingDirectory: String?, platform: RemoteMachinePlatform = .linux
    ) -> String? {
        guard !words.isEmpty else { return nil }
        let command =
            platform == .windows
            ? PowerShell.invocation(words)!
            : words.joined(separator: " ")
        return MachineWorkingDirectory.prefixed(
            command, directory: workingDirectory, platform: platform, interactive: true)
    }
}

public enum MachineMountOperation: String, CaseIterable, Equatable, Sendable {
    case mount
    case unmount

    public var descriptor: UserOperationDescriptor {
        switch self {
        case .mount:
            descriptor("mount", "Mount a machine file system on this Mac.")
        case .unmount:
            descriptor("unmount", "Unmount a machine file system from this Mac.")
        }
    }

    private func descriptor(_ verb: String, _ summary: String) -> UserOperationDescriptor {
        UserOperationDescriptor(
            id: UserOperationID(rawValue: "machines.\(rawValue)"), summary: summary,
            cli: ["machines", verb], effect: .write)
    }
}

public enum MachineMountOperationError: LocalizedError, Equatable, Sendable {
    case restoreFailed(MachineMount, String)

    public var errorDescription: String? {
        switch self {
        case let .restoreFailed(mount, message):
            "Could not restore \(mount.mountPoint): \(message)"
        }
    }
}

public struct MachineMountOperationResult: Equatable, Sendable {
    public let operation: MachineMountOperation
    public let mount: MachineMount
    public let restored: Bool

    public init(operation: MachineMountOperation, mount: MachineMount, restored: Bool = false) {
        self.operation = operation
        self.mount = mount
        self.restored = restored
    }
}

public enum MachineMountOperationExecution {
    public typealias Restore = (Machine) async -> MountRepair
    public typealias Mount = (Machine, String, URL?, Bool) async throws -> MachineMount
    public typealias Unmount = (Machine) async throws -> MachineMount

    public static func perform(
        _ operation: MachineMountOperation, machine: Machine, remotePath: String = "/",
        platform: RemoteMachinePlatform = .linux, mountPoint: URL? = nil,
        readOnly: Bool = false, restoreDefault: Bool = false,
        restore: Restore = { await MachineMounts.restore(machine: $0) },
        mount: Mount = {
            try await MachineMounts.mount(
                machine: $0, remotePath: $1, at: $2, readOnly: $3)
        },
        unmount: Unmount = { try await MachineMounts.unmount(machine: $0) }
    ) async -> Result<MachineMountOperationResult, Error> {
        do {
            switch operation {
            case .mount:
                if restoreDefault {
                    switch await restore(machine) {
                    case let .remounted(existing):
                        return .success(
                            MachineMountOperationResult(
                                operation: operation, mount: existing, restored: true))
                    case let .healthy(existing):
                        return .failure(MachineMountError.alreadyMounted(existing.mountPoint))
                    case let .failed(existing, message):
                        return .failure(
                            MachineMountOperationError.restoreFailed(existing, message))
                    case .nothingToDo:
                        break
                    }
                }
                let normalized = MachineMounts.remotePath(remotePath, platform: platform)
                let mounted = try await mount(machine, normalized, mountPoint, readOnly)
                return .success(
                    MachineMountOperationResult(operation: operation, mount: mounted))
            case .unmount:
                let released = try await unmount(machine)
                return .success(
                    MachineMountOperationResult(operation: operation, mount: released))
            }
        } catch {
            return .failure(error)
        }
    }
}

public enum MachineBroadcastOperation: String, CaseIterable, Equatable, Sendable {
    case fleet

    public var descriptor: UserOperationDescriptor {
        UserOperationDescriptor(
            id: UserOperationID(rawValue: "machines.broadcast.fleet"),
            summary: "Run one command over SSH on every selected machine.",
            cli: ["machines", "broadcast"], effect: .write)
    }
}

public enum MachineTerminalBroadcastOperation: String, CaseIterable, Equatable, Sendable {
    case send

    public var descriptor: UserOperationDescriptor {
        UserOperationDescriptor(
            id: UserOperationID(rawValue: "machines.terminal.broadcast"),
            summary: "Send one line to every open terminal tab for one machine.",
            cli: ["machines", "terminal", "broadcast"], effect: .write)
    }
}

public enum MachineTerminalBroadcastIPC {
    public static let requestIDKey = "requestID"
    public static let machineIDKey = "machineID"
    public static let commandKey = "command"
    public static let okKey = "ok"
    public static let tabCountKey = "tabCount"
    public static let unavailableTabCountKey = "unavailableTabCount"
    public static let errorCodeKey = "errorCode"
    public static let errorKey = "error"
    public static let noOpenTabsCode = "noOpenTabs"
    public static let noLiveTabsCode = "noLiveTabs"
    public static let partialDeliveryCode = "partialDelivery"
    public static let invalidRequestCode = "invalidRequest"
}

public struct MachineTerminalBroadcastDelivery: Equatable, Sendable {
    public let sent: Int
    public let unavailable: Int

    public init(sent: Int, unavailable: Int) {
        self.sent = sent
        self.unavailable = unavailable
    }

    public var total: Int { sent + unavailable }
    public var isComplete: Bool { sent > 0 && unavailable == 0 }
}

public enum MachineBroadcastOperationError: LocalizedError, Equatable, Sendable {
    case emptyCommand

    public var errorDescription: String? { "Give a command to run." }
}

public struct MachineBroadcastPlan: Equatable, Sendable {
    public let command: String

    public init(command: String) {
        self.command = command
    }

    public var terminalInput: String { command + "\n" }

    public func remoteCommand(for platform: RemoteMachinePlatform) -> String {
        platform == .windows ? PowerShell.userCommand(command) : command
    }
}

public enum MachineBroadcastOperationExecution {
    public static func plan(words: [String]) -> Result<MachineBroadcastPlan, Error> {
        var commandWords = words
        if commandWords.first == "--" { commandWords.removeFirst() }
        return plan(command: commandWords.joined(separator: " "))
    }

    public static func plan(command: String) -> Result<MachineBroadcastPlan, Error> {
        let normalized = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            return .failure(MachineBroadcastOperationError.emptyCommand)
        }
        return .success(MachineBroadcastPlan(command: normalized))
    }
}
