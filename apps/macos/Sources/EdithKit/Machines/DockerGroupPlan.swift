import Foundation

public struct DockerGroupPlan: Equatable, Sendable {
    public let startable: [DockerContainer]
    public let stoppable: [DockerContainer]

    public init(containers: [DockerContainer]) {
        startable = containers.filter { Self.isStartable($0.state) }
        stoppable = containers.filter { Self.isStoppable($0.state) }
    }

    public var canStart: Bool { !startable.isEmpty }
    public var canStop: Bool { !stoppable.isEmpty }
    public var isMixed: Bool { canStart && canStop }

    public static func isStartable(_ state: DockerContainerState) -> Bool {
        switch state {
        case .created, .exited, .dead: return true
        case .running, .restarting, .paused, .removing, .unknown: return false
        }
    }

    public static func isStoppable(_ state: DockerContainerState) -> Bool {
        switch state {
        case .running, .restarting, .paused: return true
        case .created, .exited, .dead, .removing, .unknown: return false
        }
    }
}
