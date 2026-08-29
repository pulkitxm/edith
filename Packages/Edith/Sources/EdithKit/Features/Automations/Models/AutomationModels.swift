import EdithCore
import Foundation

public enum AutomationWeekday: Int, CaseIterable, Codable, Hashable, Sendable {
    case sunday = 1
    case monday
    case tuesday
    case wednesday
    case thursday
    case friday
    case saturday
}

public enum AutomationApplicationEvent: String, Codable, Sendable {
    case launched
    case terminated
}

public enum AutomationPowerSource: String, Codable, Sendable {
    case battery
    case adapter
}

public enum AutomationThresholdDirection: String, Codable, Sendable {
    case fallsBelow
    case risesAbove
}

public enum AutomationDisplayEvent: String, Codable, Sendable {
    case attached
    case detached
}

public enum AutomationScreenEvent: String, Codable, Sendable {
    case locked
    case unlocked
}

public enum AutomationNetworkState: String, Codable, Sendable {
    case reachable
    case unreachable
}

public enum AutomationCalendarPhase: String, Codable, Sendable {
    case starts
    case ends
}

public enum AutomationTriggerKind: String, CaseIterable, Codable, Sendable {
    case schedule
    case application
    case power
    case battery
    case display
    case screen
    case wake
    case network
    case calendar
}

public enum AutomationTrigger: Codable, Equatable, Sendable {
    case schedule(hour: Int, minute: Int, weekdays: Set<AutomationWeekday>)
    case application(bundleIdentifier: String, event: AutomationApplicationEvent)
    case powerSource(AutomationPowerSource)
    case battery(level: Int, direction: AutomationThresholdDirection)
    case display(AutomationDisplayEvent)
    case screen(AutomationScreenEvent)
    case wake
    case network(AutomationNetworkState)
    case calendar(titleContains: String?, phase: AutomationCalendarPhase)

    public var kind: AutomationTriggerKind {
        switch self {
        case .schedule: .schedule
        case .application: .application
        case .powerSource: .power
        case .battery: .battery
        case .display: .display
        case .screen: .screen
        case .wake: .wake
        case .network: .network
        case .calendar: .calendar
        }
    }
}

public enum AutomationPermission: String, CaseIterable, Codable, Hashable, Sendable {
    case accessibility
    case calendar
    case fullDisk
    case inputMonitoring
    case notifications
    case screenRecording
}

public enum AutomationErrorPolicy: String, Codable, Sendable {
    case stop
    case continueOnError
}

public struct AutomationShortcut: Codable, Equatable, Sendable {
    public var keyCode: Int
    public var modifiers: Int
    public var label: String

    public init(keyCode: Int, modifiers: Int, label: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.label = label
    }
}

public struct AutomationAction: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var operationID: String
    public var arguments: [String]
    public var timeoutSeconds: Double
    public var requiredPermissions: Set<AutomationPermission>

    public init(
        id: UUID = UUID(), operationID: String, arguments: [String] = [],
        timeoutSeconds: Double = 30,
        requiredPermissions: Set<AutomationPermission> = []
    ) {
        self.id = id
        self.operationID = operationID
        self.arguments = arguments
        self.timeoutSeconds = timeoutSeconds
        self.requiredPermissions = requiredPermissions
    }
}

public struct AutomationScene: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var isEnabled: Bool
    public var actions: [AutomationAction]
    public var errorPolicy: AutomationErrorPolicy
    public var cooldownSeconds: Double
    public var shortcut: AutomationShortcut?
    public var notifiesOnCompletion: Bool

    public init(
        id: UUID = UUID(), name: String, isEnabled: Bool = true,
        actions: [AutomationAction], errorPolicy: AutomationErrorPolicy = .stop,
        cooldownSeconds: Double = 0, shortcut: AutomationShortcut? = nil,
        notifiesOnCompletion: Bool = false
    ) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.actions = actions
        self.errorPolicy = errorPolicy
        self.cooldownSeconds = cooldownSeconds
        self.shortcut = shortcut
        self.notifiesOnCompletion = notifiesOnCompletion
    }
}

public struct AutomationRule: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var isEnabled: Bool
    public var trigger: AutomationTrigger
    public var sceneID: UUID

    public init(
        id: UUID = UUID(), name: String, isEnabled: Bool = true,
        trigger: AutomationTrigger, sceneID: UUID
    ) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.trigger = trigger
        self.sceneID = sceneID
    }
}

public struct AutomationDocument: Codable, Equatable, Sendable {
    public var version: Int
    public var scenes: [AutomationScene]
    public var automations: [AutomationRule]

    public init(
        version: Int = 1, scenes: [AutomationScene] = [], automations: [AutomationRule] = []
    ) {
        self.version = version
        self.scenes = scenes
        self.automations = automations
    }
}

public enum AutomationRunOrigin: String, Codable, Sendable {
    case app
    case menuPanel
    case commandBar
    case globalShortcut
    case commandLine
    case trigger
}

public enum AutomationStepState: String, Codable, Sendable {
    case succeeded
    case failed
    case cancelled
    case timedOut
    case skipped
}

public struct AutomationStepResult: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var operationID: String
    public var state: AutomationStepState
    public var startedAt: Date
    public var duration: Double
    public var output: String

    public init(
        id: UUID, operationID: String, state: AutomationStepState, startedAt: Date,
        duration: Double, output: String
    ) {
        self.id = id
        self.operationID = operationID
        self.state = state
        self.startedAt = startedAt
        self.duration = duration
        self.output = output
    }
}

public struct AutomationRunRecord: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var sceneID: UUID
    public var sceneName: String
    public var automationID: UUID?
    public var origin: AutomationRunOrigin
    public var startedAt: Date
    public var duration: Double
    public var steps: [AutomationStepResult]

    public init(
        id: UUID, sceneID: UUID, sceneName: String, automationID: UUID?,
        origin: AutomationRunOrigin, startedAt: Date, duration: Double,
        steps: [AutomationStepResult]
    ) {
        self.id = id
        self.sceneID = sceneID
        self.sceneName = sceneName
        self.automationID = automationID
        self.origin = origin
        self.startedAt = startedAt
        self.duration = duration
        self.steps = steps
    }

    public var succeeded: Bool {
        steps.allSatisfy { $0.state == .succeeded || $0.state == .skipped }
    }
}
