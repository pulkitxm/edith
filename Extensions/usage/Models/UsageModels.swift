import Foundation

public struct SourceInfo: Identifiable {
    public let id: String
    public let label: String

    public init(id: String, label: String) {
        self.id = id
        self.label = label
    }
}

public struct DayPoint: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let date: Date
    public let cost: Double
    public let tokens: Double

    public init(id: String, date: Date, cost: Double, tokens: Double) {
        self.id = id
        self.date = date
        self.cost = cost
        self.tokens = tokens
    }
}
