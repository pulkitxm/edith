import Foundation

public struct UsageShareDay: Equatable, Sendable {
    public let period: String
    public let tokens: Double
    public let cost: Double

    public init(period: String, tokens: Double, cost: Double) {
        self.period = period
        self.tokens = max(0, tokens)
        self.cost = max(0, cost)
    }

    public var active: Bool { tokens > 0 || cost > 0 }
}

public struct UsageShareSnapshot: Equatable, Sendable {
    public let days: [UsageShareDay]
    public let agentCount: Int
    public let repositoryCount: Int
    public let generatedAt: String?

    public init(
        days: [UsageShareDay], agentCount: Int, repositoryCount: Int,
        generatedAt: String? = nil
    ) {
        self.days = days.sorted { $0.period < $1.period }
        self.agentCount = max(0, agentCount)
        self.repositoryCount = max(0, repositoryCount)
        self.generatedAt = generatedAt
    }

    public var totalTokens: Double { days.reduce(0) { $0 + $1.tokens } }
    public var totalCost: Double { days.reduce(0) { $0 + $1.cost } }
    public var activeDays: Int { days.count(where: \.active) }
    public var busiestDay: UsageShareDay? { days.max { $0.tokens < $1.tokens } }
    public var averageTokensPerActiveDay: Double {
        activeDays > 0 ? totalTokens / Double(activeDays) : 0
    }

    public var longestStreak: Int {
        let calendar = Calendar(identifier: .gregorian)
        let activeDates = days.filter(\.active).compactMap { Self.date(from: $0.period) }
        guard !activeDates.isEmpty else { return 0 }
        var longest = 1
        var current = 1
        for index in activeDates.indices.dropFirst() {
            let previous = activeDates[activeDates.index(before: index)]
            let distance = calendar.dateComponents([.day], from: previous, to: activeDates[index]).day
            if distance == 1 {
                current += 1
                longest = max(longest, current)
            } else if distance != 0 {
                current = 1
            }
        }
        return longest
    }

    public static func date(from period: String) -> Date? {
        let parts = period.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return Calendar(identifier: .gregorian).date(
            from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
}

public enum UsageShareCard: String, CaseIterable, Identifiable, Sendable {
    case highlights
    case activity
    case daily
    case busiest

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .highlights: return "Highlights"
        case .activity: return "Activity calendar"
        case .daily: return "Daily token rhythm"
        case .busiest: return "Busiest day"
        }
    }

    public var filenameStem: String { "edith-usage-\(rawValue)" }
}
