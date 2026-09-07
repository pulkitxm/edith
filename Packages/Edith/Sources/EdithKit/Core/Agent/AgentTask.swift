import Foundation

public enum AgentTaskOperation {
    public static let submit = "task.submit"
    public static let status = "task.status"
    public static let cancel = "task.cancel"
    public static let list = "task.list"
    public static let command = "command.run"
    public static let internalOperations = [submit, status, cancel, list]
}

public enum AgentTaskState: String, Codable, Sendable {
    case queued
    case running
    case cancelling
    case succeeded
    case failed
    case cancelled
    case interrupted

    public var isTerminal: Bool {
        switch self {
        case .queued, .running, .cancelling: false
        case .succeeded, .failed, .cancelled, .interrupted: true
        }
    }
}

public struct AgentTaskSubmission: Codable, Sendable {
    public let id: UUID
    public let operation: String
    public let title: String
    public let payload: Data

    public init(id: UUID = UUID(), operation: String, title: String, payload: Data) {
        self.id = id
        self.operation = operation
        self.title = String(title.prefix(160))
        self.payload = payload
    }
}

public struct AgentTaskSnapshot: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public var operation: String
    public var title: String
    public var state: AgentTaskState
    public let submittedAt: Date
    public var startedAt: Date?
    public var finishedAt: Date?
    public var lastActivity: String?
    public var failure: String?
    public var failureCode: String?

    public init(
        id: UUID, operation: String, title: String, state: AgentTaskState = .queued,
        submittedAt: Date = Date(), startedAt: Date? = nil, finishedAt: Date? = nil,
        lastActivity: String? = nil, failure: String? = nil, failureCode: String? = nil
    ) {
        self.id = id
        self.operation = operation
        self.title = title
        self.state = state
        self.submittedAt = submittedAt
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.lastActivity = lastActivity
        self.failure = failure
        self.failureCode = failureCode
    }
}

public enum AgentTaskOutputStream: String, Codable, Sendable {
    case activity
    case standardOutput
    case standardError
}

public struct AgentTaskOutput: Codable, Equatable, Sendable {
    public let sequence: Int
    public let stream: AgentTaskOutputStream
    public let text: String

    public init(sequence: Int, stream: AgentTaskOutputStream, text: String) {
        self.sequence = sequence
        self.stream = stream
        self.text = text
    }
}

public struct AgentTaskStatus: Codable, Equatable, Sendable {
    public var snapshot: AgentTaskSnapshot
    public var output: [AgentTaskOutput]
    public var result: Data?

    public init(snapshot: AgentTaskSnapshot, output: [AgentTaskOutput] = [], result: Data? = nil) {
        self.snapshot = snapshot
        self.output = output
        self.result = result
    }
}

public struct AgentTaskIDRequest: Codable, Sendable {
    public let id: UUID
    public init(id: UUID) { self.id = id }
}

public struct AgentTaskFailure: LocalizedError, Sendable {
    public let snapshot: AgentTaskSnapshot
    public let result: Data?
    public var errorDescription: String? {
        snapshot.failure ?? "The background task did not finish."
    }
    public init(snapshot: AgentTaskSnapshot, result: Data? = nil) {
        self.snapshot = snapshot
        self.result = result
    }
}

public struct AgentTaskExecutionError: LocalizedError, Sendable {
    public let code: String
    public let message: String
    public let result: Data?
    public var errorDescription: String? { message }

    public init(code: String, message: String, result: Data? = nil) {
        self.code = code
        self.message = message
        self.result = result
    }
}
