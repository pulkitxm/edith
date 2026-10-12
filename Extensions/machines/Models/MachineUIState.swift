import Foundation

public struct MachineUIState: Codable, Sendable {
    public var machines: [Machine]
    public var forwards: [PortForward]
    public var snippets: [CommandSnippet]
    public var sessions: [MachineUISessionState]
    public var workspaces: WorkspaceStore
    var clipboardStates: [UUID: SSHClipboardSyncState] = [:]
}

public struct MachineUISessionState: Codable, Sendable {
    public var machine: Machine
    public var state: MachineConnectionState
    public var platform: RemoteMachinePlatform?
    public var hello: MachineHello?
    public var slow: MachineSlow?
    public var sample: MachineSample?
    public var docker: DockerAvailability
    public var containersLoaded: Bool
    public var containersError: String?
    public var containers: [DockerContainer]
    public var images: [DockerImage]
    public var volumes: [DockerVolume]
    public var diskUsage: [DockerDiskUsage]
    public var networks: [DockerNetwork]
    public var services: [SystemdService]
    public var facts: MachineSessionSummary
    public var activeForwards: Set<UUID>
    public var mountsAvailable: Bool = false
    public var defaultMountPath: String = ""
    public var mount: MachineMount?
    public var mountHealth: MountHealth?
    public var isRemounting: Bool
    public var isApplyingPlatformProfile: Bool
    public var platformProfileRevertsAt: Date?
    public var internetSpeed: InternetSpeedMeasurement?
    public var internetSpeedError: String?
    public var isTestingInternetSpeed: Bool
    public var histories: [[Double]]
}

public struct MachineUIAction: Codable, Sendable {
    public enum Operation: String, Codable, Sendable {
        case connect, disconnect, retry, observe, dockerObserve, speedObserve
        case power, service, revealMount, openDockerPort, openForward, openFile, mount, unmount,
            forwardAdd, forwardRemove, snippetAdd,
            snippetRemove
        case command, docker, refreshDocker, refreshInventory, refreshServices
        case refreshProfile, setProfile, speedTest, restoreMount, forward, listFiles, home, mkdir
    }
    public var operation: Operation
    public var machineID: UUID
    public var text: String = ""
    public var input: Data?
    public var timeout: Double = 60
    public var presentationID: UUID?
    public var entry: RemoteFileEntry?
    public var port: Int?
    public var service: MachineServiceOperation?
    public var token: UUID?
    public var active = false
    public var forward: PortForward?
    public var snippet: CommandSnippet?
    public var duration = 0

    public init(operation: Operation, machineID: UUID) {
        self.operation = operation
        self.machineID = machineID
    }

    public func validate() throws {
        guard text.utf8.count <= 32_768, !text.utf8.contains(0),
            input.map({ $0.count <= 1_048_576 }) ?? true,
            timeout.isFinite, timeout > 0, timeout <= 900,
            duration >= 0, duration <= 86_400
        else { throw MachineUIError.invalidRequest }
        if [.observe, .dockerObserve, .speedObserve].contains(operation), token == nil {
            throw MachineUIError.invalidRequest
        }
        if operation == .forward, forward?.machineID != machineID {
            throw MachineUIError.invalidRequest
        }
    }
}

public enum MachineUIError: Error, Equatable {
    case invalidRequest, unavailable, stale
}

public struct MachineUIMutation: Codable, Sendable {
    public var operation: MachineMutationOperation
    public var machine: Machine
    public var secrets: MachineSecretChanges
}

public struct MachineUIReply: Codable, Sendable {
    public let value: Data?
    public let error: String?
}

public struct MachineUIFailure: LocalizedError, Sendable {
    public let message: String
    public var errorDescription: String? { message }
}

public struct MachineUIConfigurationState: Codable, Sendable {
    public let hosts: [SSHConfigHost]
    public let sudoPasswordStored: Set<UUID>
}

struct MachineUIJobInput: Codable, Sendable {
    var presentationID: UUID?
    let operation: String
    let payload: Data
}

struct MachineUIJobPoll: Codable, Sendable {
    let id: UUID
    let consume: Bool
}

struct MachineUIJobState: Codable, Sendable {
    let complete: Bool
    let reply: MachineUIReply?
    var progress: FileOperationProgress?
}

struct MachineUIPresentation: Codable, Sendable {
    let id: UUID
}
