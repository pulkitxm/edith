import Foundation

public enum HostAgentSchedule: Codable, Equatable, Sendable {
    case interval(seconds: TimeInterval)
    case cron(expression: String)

    public static let minimumInterval: TimeInterval = 60
    public static let maximumInterval: TimeInterval = 7 * 86_400

    public static func parse(every: String?, cron: String?) throws -> HostAgentSchedule {
        switch (every, cron) {
        case (let every?, nil):
            return .interval(seconds: try seconds(every))
        case (nil, let cron?):
            do {
                return .cron(expression: try HostCronSchedule(cron).expression)
            } catch {
                throw HostAgentCommandError(.refused, error.localizedDescription)
            }
        default:
            throw HostAgentCommandError(
                .refused, "Give exactly one of an interval or a cron expression.")
        }
    }

    public static func seconds(_ text: String) throws -> TimeInterval {
        let units: [Character: TimeInterval] = ["s": 1, "m": 60, "h": 3_600, "d": 86_400]
        guard let unit = text.last, let scale = units[unit],
            let amount = Int(text.dropLast()), amount > 0
        else {
            throw HostAgentCommandError(
                .refused, "Write the interval as a number and a unit, like 15m.")
        }
        let value = TimeInterval(amount) * scale
        guard value >= minimumInterval, value <= maximumInterval else {
            throw HostAgentCommandError(
                .refused, "The interval must be between 1 minute and 7 days.")
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
            (try? HostCronSchedule(expression))?.next(after: date, calendar: calendar)
        }
    }
}

public struct HostScheduledTaskDefinition: Codable, Equatable, Sendable {
    public static let maximumTimeout: TimeInterval = 7_200

    public let name: String
    public let schedule: HostAgentSchedule
    public let executablePath: String
    public let arguments: [String]
    public let workingDirectory: String?
    public let timeout: TimeInterval

    public init(
        name: String, schedule: HostAgentSchedule, executablePath: String, arguments: [String],
        workingDirectory: String? = nil, timeout: TimeInterval = 300
    ) throws {
        guard Self.isValid(name: name) else {
            throw HostAgentCommandError(
                .refused,
                "A schedule name uses lowercase letters, digits, dots, dashes and underscores.")
        }
        guard executablePath.hasPrefix("/") else {
            throw HostAgentCommandError(.refused, "Provide an absolute executable path.")
        }
        guard timeout.isFinite, timeout > 0, timeout <= Self.maximumTimeout else {
            throw HostAgentCommandError(
                .refused, "The timeout must be between 1 second and 2 hours.")
        }
        if let workingDirectory, !workingDirectory.hasPrefix("/") {
            throw HostAgentCommandError(.refused, "Provide an absolute working directory.")
        }
        guard executablePath.utf8.count <= 4096, !executablePath.utf8.contains(0),
            workingDirectory.map({ $0.utf8.count <= 4096 && !$0.utf8.contains(0) }) ?? true,
            arguments.count <= 4096, arguments.reduce(0, { $0 + $1.utf8.count }) <= (1 << 20),
            arguments.allSatisfy({ !$0.utf8.contains(0) })
        else {
            throw HostAgentCommandError(
                .refused, "The scheduled command exceeds its argument bounds.")
        }
        switch schedule {
        case .interval(let seconds):
            guard seconds.isFinite, seconds >= HostAgentSchedule.minimumInterval,
                seconds <= HostAgentSchedule.maximumInterval
            else {
                throw HostAgentCommandError(
                    .refused, "The interval must be between 1 minute and 7 days.")
            }
        case .cron(let expression):
            guard expression.utf8.count <= 512 else {
                throw HostAgentCommandError(.refused, "The cron expression is too long.")
            }
            _ = try HostCronSchedule(expression)
        }
        self.name = name
        self.schedule = schedule
        self.executablePath = executablePath
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.timeout = timeout
    }

    public func validate() throws {
        _ = try Self(
            name: name, schedule: schedule, executablePath: executablePath, arguments: arguments,
            workingDirectory: workingDirectory, timeout: timeout)
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

public struct HostScheduledTaskSnapshot: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let definition: HostScheduledTaskDefinition
    public let enabled: Bool
    public let nextRunAt: Date?
    public let lastRunAt: Date?
    public let lastTaskID: UUID?
    public let lastState: HostAgentTaskState?

    public init(
        id: UUID, definition: HostScheduledTaskDefinition, enabled: Bool, nextRunAt: Date?,
        lastRunAt: Date?, lastTaskID: UUID?, lastState: HostAgentTaskState?
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

public struct HostAgentScheduleNameRequest: Codable, Sendable {
    public let name: String

    public init(name: String) {
        self.name = name
    }
}

public struct HostAgentScheduleEnabledRequest: Codable, Sendable {
    public let name: String
    public let enabled: Bool

    public init(name: String, enabled: Bool) {
        self.name = name
        self.enabled = enabled
    }
}

public enum HostAgentScheduleOperation {
    public static let add = "schedule.add"
    public static let list = "schedule.list"
    public static let remove = "schedule.remove"
    public static let setEnabled = "schedule.enable"
    public static let runNow = "schedule.run"
    public static let internalOperations = [add, list, remove, setEnabled, runNow]
}
