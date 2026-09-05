import Foundation

public struct AgentEvent: Codable, Equatable, Sendable, Identifiable {
    public enum Level: String, Codable, CaseIterable, Sendable {
        case info
        case warning
        case error
    }

    public let id: UUID
    public let date: Date
    public let level: Level
    public let category: String
    public let name: String
    public let message: String
    public let duration: TimeInterval?

    public init(
        id: UUID = UUID(), date: Date = Date(), level: Level = .info,
        category: String, name: String, message: String, duration: TimeInterval? = nil
    ) {
        self.id = id
        self.date = date
        self.level = level
        self.category = String(category.prefix(80))
        self.name = String(name.prefix(160))
        self.message = String(message.prefix(2_000))
        self.duration = duration
    }
}

public enum AgentDiagnostics {
    public static let capacity = 500
    public static let runJob = "diagnostics.runJob"
    public static let cancelJob = "diagnostics.cancelJob"
}
