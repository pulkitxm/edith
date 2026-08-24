import EdithCore
import Foundation

public enum MachineMutationOperation: String, CaseIterable, Sendable {
    case add
    case edit
    case remove

    public var descriptor: UserOperationDescriptor {
        switch self {
        case .add:
            descriptor("add", "Add a machine.", effect: .write)
        case .edit:
            descriptor("edit", "Edit a machine.", effect: .write)
        case .remove:
            descriptor(
                "rm", "Remove a machine and its saved data.", effect: .destructive,
                requiresPreview: true)
        }
    }

    private func descriptor(
        _ verb: String, _ summary: String, effect: UserOperationEffect,
        requiresPreview: Bool = false
    ) -> UserOperationDescriptor {
        UserOperationDescriptor(
            id: UserOperationID(rawValue: "machines.\(rawValue)"), summary: summary,
            cli: ["machines", verb], effect: effect, requiresPreview: requiresPreview)
    }
}

public struct MachineSecretChanges: Equatable, Sendable {
    public var login: String?
    public var sudoPassword: String?
    public var forgetSudoPassword: Bool

    public init(
        login: String? = nil, sudoPassword: String? = nil,
        forgetSudoPassword: Bool = false
    ) {
        self.login = login
        self.sudoPassword = sudoPassword
        self.forgetSudoPassword = forgetSudoPassword
    }
}

public struct MachineRemovalPreview: Equatable, Sendable {
    public let machine: Machine
    public let forwardCount: Int
    public let snippetCount: Int

    public init(machine: Machine, forwardCount: Int, snippetCount: Int) {
        self.machine = machine
        self.forwardCount = forwardCount
        self.snippetCount = snippetCount
    }
}

public struct MachineMutationResult: Equatable, Sendable {
    public let operation: MachineMutationOperation
    public let machine: Machine
    public let removal: MachineRemovalPreview?

    public init(
        operation: MachineMutationOperation, machine: Machine,
        removal: MachineRemovalPreview? = nil
    ) {
        self.operation = operation
        self.machine = machine
        self.removal = removal
    }
}

public enum MachineMutationOperationExecution {
    public typealias SetSecret = (String, UUID, MachineSecretKind) -> Void
    public typealias DeleteSecret = (UUID, MachineSecretKind) -> Void

    public static func removalPreview(
        _ machine: Machine, files: MachineRegistry.Files = MachineRegistry.Files()
    ) -> MachineRemovalPreview {
        let contents = MachineRegistry.load(files)
        return MachineRemovalPreview(
            machine: machine,
            forwardCount: MachineRegistry.forwards(machineID: machine.id, in: contents.forwards)
                .count,
            snippetCount: contents.snippets.filter { $0.machineID == machine.id }.count)
    }

    @discardableResult
    public static func perform(
        _ operation: MachineMutationOperation, machine: Machine,
        secrets: MachineSecretChanges = MachineSecretChanges(),
        files: MachineRegistry.Files = MachineRegistry.Files(),
        setSecret: SetSecret = { MachineSecrets.set($0, machineID: $1, kind: $2) },
        deleteSecret: DeleteSecret = { MachineSecrets.delete(machineID: $0, kind: $1) },
        notify: () -> Void
    ) -> MachineMutationResult {
        switch operation {
        case .add:
            MachineRegistry.add(machine, files)
            apply(secrets, to: machine, setSecret: setSecret, deleteSecret: deleteSecret)
            notify()
            return MachineMutationResult(operation: operation, machine: machine)
        case .edit:
            MachineRegistry.update(machine, files)
            apply(secrets, to: machine, setSecret: setSecret, deleteSecret: deleteSecret)
            notify()
            return MachineMutationResult(operation: operation, machine: machine)
        case .remove:
            let preview = removalPreview(machine, files: files)
            MachineRegistry.remove(id: machine.id, files)
            notify()
            return MachineMutationResult(
                operation: operation, machine: machine, removal: preview)
        }
    }

    private static func apply(
        _ changes: MachineSecretChanges, to machine: Machine, setSecret: SetSecret,
        deleteSecret: DeleteSecret
    ) {
        if let login = changes.login {
            setSecret(
                login, machine.id,
                machine.auth == .password ? .password : .passphrase)
        }
        if let sudoPassword = changes.sudoPassword {
            setSecret(sudoPassword, machine.id, .sudoPassword)
        }
        if changes.forgetSudoPassword {
            deleteSecret(machine.id, .sudoPassword)
        }
    }
}

public enum MachinePowerOperation: String, CaseIterable, Sendable {
    case reboot
    case shutdown
    case wake

    public var descriptor: UserOperationDescriptor {
        switch self {
        case .reboot:
            descriptor(
                "reboot", "Restart a machine.", effect: .destructive,
                requiresPreview: true)
        case .shutdown:
            descriptor(
                "shutdown", "Shut a machine down.", effect: .destructive,
                requiresPreview: true)
        case .wake:
            descriptor("wake", "Wake a machine over the local network.", effect: .write)
        }
    }

    private func descriptor(
        _ verb: String, _ summary: String, effect: UserOperationEffect,
        requiresPreview: Bool = false
    ) -> UserOperationDescriptor {
        UserOperationDescriptor(
            id: UserOperationID(rawValue: "machines.power.\(rawValue)"), summary: summary,
            cli: ["machines", "power", verb], effect: effect,
            requiresPreview: requiresPreview)
    }
}

public struct MachinePowerResult: Equatable, Sendable {
    public let operation: MachinePowerOperation
    public let machine: Machine
    public let macAddress: String?

    public init(
        operation: MachinePowerOperation, machine: Machine, macAddress: String? = nil
    ) {
        self.operation = operation
        self.machine = machine
        self.macAddress = macAddress
    }
}

public enum MachinePowerOperationError: LocalizedError, Equatable, Sendable {
    case missingWakeAddress(String)
    case invalidWakeAddress(String)
    case wakeFailed(String)
    case remoteExecutionUnavailable

    public var errorDescription: String? {
        switch self {
        case let .missingWakeAddress(machine):
            return "No MAC address is stored for \(machine)."
        case let .invalidWakeAddress(address):
            return "\(address) is not a MAC address."
        case let .wakeFailed(message):
            return message
        case .remoteExecutionUnavailable:
            return "The machine has no remote command connection."
        }
    }
}

public enum MachinePowerOperationExecution {
    public typealias Run = (String, Data?, TimeInterval) async -> Result<String, Error>
    public typealias SendWakePacket = (Data) -> String?

    public static func command(
        for operation: MachinePowerOperation, machineID: UUID,
        sudoPassword: (UUID) -> Data? = { SudoPassword.stdin(machineID: $0) }
    ) -> (command: String, stdin: Data?)? {
        guard operation != .wake else { return nil }
        let stdin = sudoPassword(machineID)
        let command =
            operation == .reboot
            ? PowerCommands.reboot(withSudoPassword: stdin != nil)
            : PowerCommands.shutdown(withSudoPassword: stdin != nil)
        return (command, stdin)
    }

    public static func perform(
        _ operation: MachinePowerOperation, machine: Machine,
        learnedMACAddress: String? = nil,
        sudoPassword: (UUID) -> Data? = { SudoPassword.stdin(machineID: $0) },
        run: Run = { _, _, _ in
            .failure(MachinePowerOperationError.remoteExecutionUnavailable)
        },
        sendWakePacket: SendWakePacket = MagicPacket.send
    ) async -> Result<MachinePowerResult, Error> {
        if operation == .wake {
            guard let address = machine.wakeMACAddress ?? learnedMACAddress else {
                return .failure(MachinePowerOperationError.missingWakeAddress(machine.name))
            }
            guard let packet = WakeOnLAN.magicPacket(macAddress: address) else {
                return .failure(MachinePowerOperationError.invalidWakeAddress(address))
            }
            if let failure = sendWakePacket(packet) {
                return .failure(MachinePowerOperationError.wakeFailed(failure))
            }
            return .success(
                MachinePowerResult(
                    operation: operation, machine: machine, macAddress: address))
        }
        guard
            let request = command(
                for: operation, machineID: machine.id, sudoPassword: sudoPassword)
        else {
            return .failure(MachinePowerOperationError.remoteExecutionUnavailable)
        }
        switch await run(request.command, request.stdin, 20) {
        case .success:
            return .success(MachinePowerResult(operation: operation, machine: machine))
        case let .failure(error) where PowerOutcome.hostWentAway(error):
            return .success(MachinePowerResult(operation: operation, machine: machine))
        case let .failure(error):
            return .failure(error)
        }
    }
}

public enum MachineConnectionOperation: String, CaseIterable, Sendable {
    case connect
    case disconnect

    public var descriptor: UserOperationDescriptor {
        UserOperationDescriptor(
            id: UserOperationID(rawValue: "machines.connection.\(rawValue)"),
            summary: rawValue == "connect" ? "Connect to a machine." : "Disconnect a machine.",
            cli: ["machines", rawValue], effect: .write)
    }
}

public struct MachineConnectionResult: Equatable, Sendable {
    public let operation: MachineConnectionOperation
    public let connected: Bool
    public let latencyMillis: Double?

    public init(
        operation: MachineConnectionOperation, connected: Bool, latencyMillis: Double? = nil
    ) {
        self.operation = operation
        self.connected = connected
        self.latencyMillis = latencyMillis
    }
}

public enum MachineConnectionOperationExecution {
    public static func perform(
        _ operation: MachineConnectionOperation,
        connect: () async throws -> Double?, disconnect: () async -> Void
    ) async rethrows -> MachineConnectionResult {
        switch operation {
        case .connect:
            return MachineConnectionResult(
                operation: operation, connected: true,
                latencyMillis: try await connect())
        case .disconnect:
            await disconnect()
            return MachineConnectionResult(operation: operation, connected: false)
        }
    }
}
