import EdithExtensionSupport
import Foundation

public enum CodeStatsExportCard: String, CaseIterable, Identifiable, Sendable {
    case highlights
    case languages
    case rhythm

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .highlights: "Highlights"
        case .languages: "Languages"
        case .rhythm: "Rhythm"
        }
    }

    public var filenameStem: String { "edith-code-stats-\(rawValue)" }
}

public struct CodeStatsExportSnapshot: Codable, Equatable, Sendable {
    public struct Language: Codable, Equatable, Sendable {
        public let name: String
        public let lines: Int
        public let share: Double
    }

    public static let languageLimit = 6
    static let weekdays = [
        "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday",
    ]

    public let rangeLabel: String
    public let startDay: String
    public let endDay: String
    public let commits: Int
    public let linesAuthored: Int
    public let linesAdded: Int
    public let linesDeleted: Int
    public let netLines: Int
    public let activeDays: Int
    public let currentStreak: Int
    public let longestStreak: Int
    public let linesPerActiveDay: Int
    public let commitChange: Double?
    public let lineChange: Double?
    public let languageCount: Int
    public let languages: [Language]
    public let busiestWeekday: String?
    public let busiestWeekdayCommits: Int
    public let peakHour: Int?
    public let peakHourCommits: Int
    public let bestDay: String?
    public let bestDayLines: Int
    public let bestDayCommits: Int

    public init(report: CodeStatsReport, rangeLabel: String? = nil) {
        let totals = report.totals
        self.rangeLabel = rangeLabel ?? Self.label(for: report.range)
        startDay = report.startDay
        endDay = report.endDay
        commits = totals.commits
        linesAuthored = totals.authored
        linesAdded = totals.added
        linesDeleted = totals.deleted
        netLines = totals.net
        activeDays = totals.activeDays
        currentStreak = totals.currentStreak
        longestStreak = totals.longestStreak
        linesPerActiveDay = totals.activeDays > 0 ? totals.authored / totals.activeDays : 0
        commitChange = report.momentum?.commitChange
        lineChange = report.momentum?.lineChange
        languageCount = report.languages.count
        languages = report.languages.prefix(Self.languageLimit).map {
            Language(name: $0.language, lines: $0.counts.authored, share: $0.share)
        }
        let weekdayTotals = report.punchcard.map { $0.reduce(0, +) }
        let busiestWeekday = Self.peak(weekdayTotals)
        self.busiestWeekday = busiestWeekday.flatMap { Self.weekdays[safe: $0.index] }
        busiestWeekdayCommits = busiestWeekday?.value ?? 0
        var hourTotals = Array(repeating: 0, count: 24)
        for row in report.punchcard {
            for (hour, value) in row.enumerated() where hour < 24 { hourTotals[hour] += value }
        }
        let peakHour = Self.peak(hourTotals)
        self.peakHour = peakHour?.index
        peakHourCommits = peakHour?.value ?? 0
        let best = report.topDays.first
        bestDay = best?.day
        bestDayLines = best?.counts.authored ?? 0
        bestDayCommits = best?.commits ?? 0
    }

    public var hasActivity: Bool { commits > 0 || linesAuthored > 0 }

    static func label(for range: CodeStatsRange, calendar: Calendar = .current) -> String {
        switch range {
        case .all: return "All time"
        case .days(1): return "Today"
        case .days(let count): return "Last \(count) days"
        case .year: return "Last 12 months"
        case .between(let first, let last):
            guard let start = DateFilterDay(first), let end = DateFilterDay(last) else {
                return first + " to " + last
            }
            return DateFilterRange(start, end).title(calendar: calendar)
        }
    }

    public var periodLine: String {
        Self.names(rangeLabel, first: startDay, last: endDay)
            ? rangeLabel : "\(rangeLabel)  ·  \(startDay) to \(endDay)"
    }

    private static func names(_ text: String, first: String, last: String) -> Bool {
        text == label(for: .between(first, last))
    }

    private static func peak(_ values: [Int]) -> (index: Int, value: Int)? {
        guard let best = values.enumerated().max(by: { $0.element < $1.element }),
            best.element > 0
        else { return nil }
        return (best.offset, best.element)
    }
}

extension Array {
    fileprivate subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
