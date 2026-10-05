import Foundation

public enum AgentSchedule: Codable, Equatable, Sendable {
    case interval(seconds: TimeInterval)
    case cron(expression: String)

    public static let minimumInterval: TimeInterval = 60
    public static let maximumInterval: TimeInterval = 7 * 86_400

    public static func parse(every: String?, cron: String?) throws -> AgentSchedule {
        switch (every, cron) {
        case (let every?, nil):
            return .interval(seconds: try seconds(every))
        case (nil, let cron?):
            do {
                return .cron(expression: try CronSchedule(cron).expression)
            } catch {
                throw AgentError(.refused, error.localizedDescription)
            }
        default:
            throw AgentError(.refused, "Give exactly one of an interval or a cron expression.")
        }
    }

    public static func seconds(_ text: String) throws -> TimeInterval {
        let units: [Character: TimeInterval] = ["s": 1, "m": 60, "h": 3_600, "d": 86_400]
        guard let unit = text.last, let scale = units[unit],
            let amount = Int(text.dropLast()), amount > 0
        else {
            throw AgentError(.refused, "Write the interval as a number and a unit, like 15m.")
        }
        let value = TimeInterval(amount) * scale
        guard value >= minimumInterval, value <= maximumInterval else {
            throw AgentError(.refused, "The interval must be between 1 minute and 7 days.")
        }
        return value
    }

    public var text: String {
        switch self {
        case .interval(let seconds): "every \(Self.intervalText(seconds))"
        case .cron(let expression): "cron \(expression)"
        }
    }

    private static func intervalText(_ seconds: TimeInterval) -> String {
        let whole = Int(seconds)
        for (unit, scale) in [("d", 86_400), ("h", 3_600), ("m", 60)] where whole % scale == 0 {
            return "\(whole / scale)\(unit)"
        }
        return "\(whole)s"
    }

    public func next(after date: Date, calendar: Calendar = .current) -> Date? {
        switch self {
        case .interval(let seconds):
            date.addingTimeInterval(seconds)
        case .cron(let expression):
            (try? CronSchedule(expression))?.next(after: date, calendar: calendar)
        }
    }
}

public struct ScheduledTaskDefinition: Codable, Equatable, Sendable {
    public static let maximumTimeout: TimeInterval = 7_200

    public let name: String
    public let schedule: AgentSchedule
    public let executablePath: String
    public let arguments: [String]
    public let workingDirectory: String?
    public let timeout: TimeInterval

    public init(
        name: String, schedule: AgentSchedule, executablePath: String, arguments: [String],
        workingDirectory: String? = nil, timeout: TimeInterval = 300
    ) throws {
        guard Self.isValid(name: name) else {
            throw AgentError(
                .refused,
                "A schedule name uses lowercase letters, digits, dots, dashes and underscores.")
        }
        guard executablePath.hasPrefix("/") else {
            throw AgentError(.refused, "Provide an absolute executable path.")
        }
        guard timeout.isFinite, timeout > 0, timeout <= Self.maximumTimeout else {
            throw AgentError(.refused, "The timeout must be between 1 second and 2 hours.")
        }
        if let workingDirectory, !workingDirectory.hasPrefix("/") {
            throw AgentError(.refused, "Provide an absolute working directory.")
        }
        self.name = name
        self.schedule = schedule
        self.executablePath = executablePath
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.timeout = timeout
    }

    public static func isValid(name: String) -> Bool {
        guard (1...64).contains(name.count), let first = name.first,
            first.isASCII, first.isLowercase || first.isNumber
        else { return false }
        return name.allSatisfy {
            $0.isASCII && ($0.isLowercase || $0.isNumber || "._-".contains($0))
        }
    }

    public var commandLine: String {
        ([executablePath] + arguments).joined(separator: " ")
    }
}

public struct ScheduledTaskSnapshot: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let definition: ScheduledTaskDefinition
    public let enabled: Bool
    public let nextRunAt: Date?
    public let lastRunAt: Date?
    public let lastTaskID: UUID?
    public let lastState: AgentTaskState?

    public init(
        id: UUID, definition: ScheduledTaskDefinition, enabled: Bool, nextRunAt: Date?,
        lastRunAt: Date?, lastTaskID: UUID?, lastState: AgentTaskState?
    ) {
        self.id = id
        self.definition = definition
        self.enabled = enabled
        self.nextRunAt = nextRunAt
        self.lastRunAt = lastRunAt
        self.lastTaskID = lastTaskID
        self.lastState = lastState
    }
}

public struct AgentScheduleNameRequest: Codable, Sendable {
    public let name: String

    public init(name: String) {
        self.name = name
    }
}

public struct AgentScheduleEnabledRequest: Codable, Sendable {
    public let name: String
    public let enabled: Bool

    public init(name: String, enabled: Bool) {
        self.name = name
        self.enabled = enabled
    }
}

public enum AgentScheduleOperation {
    public static let add = "schedule.add"
    public static let list = "schedule.list"
    public static let remove = "schedule.remove"
    public static let setEnabled = "schedule.enable"
    public static let runNow = "schedule.run"
    public static let internalOperations = [add, list, remove, setEnabled, runNow]
}

public struct AgentScheduleClient: Sendable {
    public let client: AgentClient

    public init(client: AgentClient = .shared) {
        self.client = client
    }

    public func add(_ definition: ScheduledTaskDefinition) async throws -> ScheduledTaskSnapshot {
        try AgentPayload.decode(
            ScheduledTaskSnapshot.self,
            from: await client.performInternalAsync(
                AgentScheduleOperation.add, payload: AgentPayload.encode(definition)))
    }

    public func list() async throws -> [ScheduledTaskSnapshot] {
        try AgentPayload.decode(
            [ScheduledTaskSnapshot].self,
            from: await client.performInternalAsync(AgentScheduleOperation.list))
    }

    public func remove(_ name: String) async throws {
        _ = try await client.performInternalAsync(
            AgentScheduleOperation.remove,
            payload: AgentPayload.encode(AgentScheduleNameRequest(name: name)))
    }

    public func setEnabled(_ name: String, _ enabled: Bool) async throws -> ScheduledTaskSnapshot {
        try AgentPayload.decode(
            ScheduledTaskSnapshot.self,
            from: await client.performInternalAsync(
                AgentScheduleOperation.setEnabled,
                payload: AgentPayload.encode(
                    AgentScheduleEnabledRequest(name: name, enabled: enabled))))
    }

    public func runNow(_ name: String) async throws -> AgentTaskSnapshot {
        try AgentPayload.decode(
            AgentTaskSnapshot.self,
            from: await client.performInternalAsync(
                AgentScheduleOperation.runNow,
                payload: AgentPayload.encode(AgentScheduleNameRequest(name: name))))
    }
}
