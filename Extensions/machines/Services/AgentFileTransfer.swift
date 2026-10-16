import EdithExtensionSupport
import Foundation

public enum AgentFileTransferLocation: Codable, Equatable, Sendable {
    case local
    case remote(Machine)

    public var name: String {
        switch self {
        case .local: "This Mac"
        case let .remote(machine): machine.name
        }
    }
}

public struct AgentFileTransferRequest: Codable, Sendable {
    public static let operation = "machine.files.transfer"
    public let plan: RemoteTransferPlan
    public let source: AgentFileTransferLocation
    public let destination: AgentFileTransferLocation
    public let confirmsReplacement: Bool
    public let moving: Bool

    public init(
        plan: RemoteTransferPlan, source: AgentFileTransferLocation,
        destination: AgentFileTransferLocation, confirmsReplacement: Bool, moving: Bool = false
    ) {
        self.plan = plan
        self.source = source
        self.destination = destination
        self.confirmsReplacement = confirmsReplacement
        self.moving = moving
    }
}
