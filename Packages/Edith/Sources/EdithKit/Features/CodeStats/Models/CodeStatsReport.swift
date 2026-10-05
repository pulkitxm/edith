import Foundation

public enum CodeStatsRange: Codable, Hashable, Sendable {
    case days(Int)
    case year
    case all
    case between(String, String)

    public static let presets: [CodeStatsRange] = [.days(30), .days(90), .year, .all]

    public init?(argument: String) {
        let bounds = argument.components(separatedBy: "..")
        if bounds.count == 2, let start = CodeStatsDay(bounds[0]), let end = CodeStatsDay(bounds[1])
        {
            self =
                start <= end
                ? .between(start.string, end.string) : .between(end.string, start.string)
            return
        }
        switch argument.lowercased() {
        case "1y", "year": self = .year
        case "all": self = .all
        default:
            guard argument.lowercased().hasSuffix("d"), let count = Int(argument.dropLast()),
                count > 0
            else { return nil }
            self = .days(count)
        }
    }

    public var argument: String {
        switch self {
        case .days(let count): "\(count)d"
        case .year: "1y"
        case .all: "all"
        case .between(let start, let end): start + ".." + end
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let argument = try container.decode(String.self)
        guard let range = CodeStatsRange(argument: argument) else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Unknown range \(argument)")
        }
        self = range
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(argument)
    }
}

public struct CodeStatsTotals: Codable, Equatable, Sendable {
    public var commits: Int
    public var authored: Int
    public var added: Int
    public var updated: Int
    public var deleted: Int
    public var net: Int
    public var activeDays: Int
    public var repositories: Int
    public var currentStreak: Int
    public var longestStreak: Int
    public var averagePerActiveDay: Double
}

public struct CodeStatsMomentum: Codable, Equatable, Sendable {
    public var commits: Int
    public var previousCommits: Int
    public var lines: Int
    public var previousLines: Int
    public var commitChange: Double?
    public var lineChange: Double?

    public init(commits: Int, previousCommits: Int, lines: Int, previousLines: Int) {
        self.commits = commits
        self.previousCommits = previousCommits
        self.lines = lines
        self.previousLines = previousLines
        commitChange = Self.change(commits, previousCommits)
        lineChange = Self.change(lines, previousLines)
    }

    static func change(_ current: Int, _ previous: Int) -> Double? {
        previous == 0 ? nil : Double(current - previous) / Double(previous) * 100
    }
}

public struct CodeStatsDayPoint: Codable, Equatable, Sendable {
    public var day: String
    public var commits: Int
    public var counts: CodeStatsLanguageCounts
}

public struct CodeStatsPeriodPoint: Codable, Equatable, Sendable {
    public var start: String
    public var commits: Int
    public var lines: Int
    public var rollingCommits: Double
    public var rollingLines: Double
}

public struct CodeStatsSeriesValue: Codable, Equatable, Sendable {
    public var start: String
    public var value: Double
}

public struct CodeStatsSeries: Codable, Equatable, Sendable {
    public var name: String
    public var values: [CodeStatsSeriesValue]
}

public struct CodeStatsRepositorySummary: Codable, Equatable, Sendable {
    public var repository: String
    public var commits: Int
    public var counts: CodeStatsLanguageCounts
    public var firstDay: String
    public var lastDay: String
    public var activeDays: Int
    public var topLanguage: String?
}

public struct CodeStatsLanguageTotal: Codable, Equatable, Sendable {
    public var language: String
    public var counts: CodeStatsLanguageCounts
    public var share: Double
}

public struct CodeStatsReport: Codable, Equatable, Sendable {
    public var range: CodeStatsRange
    public var startDay: String
    public var endDay: String
    public var totals: CodeStatsTotals
    public var momentum: CodeStatsMomentum?
    public var daily: [CodeStatsDayPoint]
    public var weekly: [CodeStatsPeriodPoint]
    public var monthly: [CodeStatsPeriodPoint]
    public var repositories: [CodeStatsRepositorySummary]
    public var repositoryMonthly: [CodeStatsSeries]
    public var languages: [CodeStatsLanguageTotal]
    public var languageMonthly: [CodeStatsSeries]
    public var punchcard: [[Int]]
    public var topDays: [CodeStatsDayPoint]
}
