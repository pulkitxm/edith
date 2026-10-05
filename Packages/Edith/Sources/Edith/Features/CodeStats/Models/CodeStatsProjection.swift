import EdithKit
import Foundation

struct CodeStatsHeatCell: Identifiable, Equatable, Sendable {
    let id: String
    let date: Date?
    let commits: Int
    let lines: Int
    let level: Int
}

struct CodeStatsHeatWeek: Identifiable, Equatable, Sendable {
    let id: Int
    let monthLabel: String
    let cells: [CodeStatsHeatCell]
}

struct CodeStatsTrendPoint: Identifiable, Equatable, Sendable {
    var id: Date { date }
    let date: Date
    let commits: Int
    let lines: Int
    let rollingCommits: Double
    let rollingLines: Double
    var totalCommits = 0
    var totalLines = 0
}

struct CodeStatsStackPoint: Identifiable, Equatable, Sendable {
    var id: String { series + "|" + String(date.timeIntervalSince1970) }
    let date: Date
    let series: String
    let value: Double
}

struct CodeStatsShare: Identifiable, Equatable, Sendable {
    var id: String { name }
    let name: String
    let lines: Int
    let share: Double
}

struct CodeStatsPunchCell: Identifiable, Equatable, Sendable {
    var id: Int { row * 24 + hour }
    let row: Int
    let weekday: String
    let hour: Int
    let commits: Int
    let level: Int
}

struct CodeStatsTopDay: Identifiable, Equatable, Sendable {
    var id: String { day }
    let day: String
    let date: Date?
    let commits: Int
    let lines: Int
}

enum CodeStatsRepositorySort: String, CaseIterable, Sendable {
    case commits
    case lines
    case lastActive

    var title: String {
        switch self {
        case .commits: "Commits"
        case .lines: "Lines"
        case .lastActive: "Last active"
        }
    }
}

enum CodeStatsTrendGranularity: Sendable {
    case weekly
    case monthly
}

struct CodeStatsProjection: Equatable, Sendable {
    static let heatmapDays = 371
    static let repositoryBarCount = 10
    static let languageShareCount = 8
    static let monthlyTrendThreshold = 104

    var heatWeeks: [CodeStatsHeatWeek] = []
    var trendGranularity = CodeStatsTrendGranularity.weekly
    var trend: [CodeStatsTrendPoint] = []
    var repositoryBars: [CodeStatsRepositorySummary] = []
    var repositoryRows: [CodeStatsRepositorySort: [CodeStatsRepositorySummary]] = [:]
    var repositoryMonthly: [CodeStatsStackPoint] = []
    var repositorySeries: [String] = []
    var languageShares: [CodeStatsShare] = []
    var languageMonthly: [CodeStatsStackPoint] = []
    var languageSeries: [String] = []
    var punchcard: [CodeStatsPunchCell] = []
    var punchcardRows: [String] = []
    var topDays: [CodeStatsTopDay] = []

    init() {}

    init(report: CodeStatsReport, calendar: Calendar = .current) {
        let dates = DateResolver(calendar: calendar)
        heatWeeks = Self.heatWeeks(report.daily, calendar: calendar, dates: dates)
        let useMonthly = report.weekly.count > Self.monthlyTrendThreshold
        trendGranularity = useMonthly ? .monthly : .weekly
        var runningCommits = 0
        var runningLines = 0
        var points: [CodeStatsTrendPoint] = []
        for point in useMonthly ? report.monthly : report.weekly {
            runningCommits += point.commits
            runningLines += point.lines
            guard let date = dates.date(point.start) else { continue }
            var trendPoint = CodeStatsTrendPoint(
                date: date, commits: point.commits, lines: point.lines,
                rollingCommits: point.rollingCommits, rollingLines: point.rollingLines)
            trendPoint.totalCommits = runningCommits
            trendPoint.totalLines = runningLines
            points.append(trendPoint)
        }
        trend = points
        repositoryBars = Array(report.repositories.prefix(Self.repositoryBarCount))
        repositoryRows = Dictionary(
            uniqueKeysWithValues: CodeStatsRepositorySort.allCases.map {
                ($0, Self.sorted(report.repositories, by: $0))
            })
        repositorySeries = report.repositoryMonthly.map(\.name)
        repositoryMonthly = Self.stack(report.repositoryMonthly, dates: dates)
        languageShares = Self.shares(report.languages)
        languageSeries = report.languageMonthly.map(\.name)
        languageMonthly = Self.stack(report.languageMonthly, dates: dates)
        punchcardRows = Self.weekdayOrder(calendar: calendar).map {
            calendar.shortWeekdaySymbols[$0]
        }
        punchcard = Self.punchcard(report.punchcard, calendar: calendar)
        topDays = report.topDays.map {
            CodeStatsTopDay(
                day: $0.day, date: dates.date($0.day), commits: $0.commits,
                lines: $0.counts.authored)
        }
    }

    static func sorted(
        _ repositories: [CodeStatsRepositorySummary], by sort: CodeStatsRepositorySort
    ) -> [CodeStatsRepositorySummary] {
        repositories.sorted { left, right in
            switch sort {
            case .commits:
                (left.commits, right.repository) > (right.commits, left.repository)
            case .lines:
                (left.counts.authored, right.repository)
                    > (right.counts.authored, left.repository)
            case .lastActive:
                (left.lastDay, right.repository) > (right.lastDay, left.repository)
            }
        }
    }

    static func levels(_ values: [Int]) -> (Int) -> Int {
        let cuts = ActivityCalendar.cuts(values.map(Double.init))
        return { ActivityCalendar.level(Double($0), cuts: cuts) }
    }

    static func weekdayOrder(calendar: Calendar) -> [Int] {
        (0..<7).map { (calendar.firstWeekday - 1 + $0) % 7 }
    }

    private static func heatWeeks(
        _ daily: [CodeStatsDayPoint], calendar: Calendar, dates: DateResolver
    ) -> [CodeStatsHeatWeek] {
        let recent = daily.suffix(heatmapDays)
        let points = Dictionary(uniqueKeysWithValues: recent.map { ($0.day, $0) })
        let days = recent.map {
            ActivityCalendarDay(id: $0.day, date: dates.date($0.day), value: Double($0.commits))
        }
        return ActivityCalendar.weeks(days: days, calendar: calendar).map { week in
            CodeStatsHeatWeek(
                id: week.id, monthLabel: week.monthLabel,
                cells: week.cells.map { cell in
                    CodeStatsHeatCell(
                        id: cell.id, date: cell.date, commits: points[cell.id]?.commits ?? 0,
                        lines: points[cell.id]?.counts.authored ?? 0, level: cell.level)
                })
        }
    }

    private static func stack(_ series: [CodeStatsSeries], dates: DateResolver)
        -> [CodeStatsStackPoint]
    {
        series.flatMap { entry in
            entry.values.compactMap { value in
                dates.date(value.start).map {
                    CodeStatsStackPoint(date: $0, series: entry.name, value: value.value)
                }
            }
        }
    }

    private static func shares(_ languages: [CodeStatsLanguageTotal]) -> [CodeStatsShare] {
        let kept = languages.prefix(languageShareCount).map {
            CodeStatsShare(name: $0.language, lines: $0.counts.authored, share: $0.share)
        }
        let rest = languages.dropFirst(languageShareCount)
        guard !rest.isEmpty else { return kept }
        return kept + [
            CodeStatsShare(
                name: CodeStatsLanguage.other + " (\(rest.count))",
                lines: rest.reduce(0) { $0 + $1.counts.authored },
                share: rest.reduce(0) { $0 + $1.share })
        ]
    }

    private static func punchcard(_ grid: [[Int]], calendar: Calendar) -> [CodeStatsPunchCell] {
        let level = levels(grid.flatMap { $0 })
        return weekdayOrder(calendar: calendar).enumerated().flatMap { row, weekday in
            (0..<24).map { hour in
                let commits =
                    grid.indices.contains(weekday) && grid[weekday].indices.contains(hour)
                    ? grid[weekday][hour] : 0
                return CodeStatsPunchCell(
                    row: row, weekday: calendar.shortWeekdaySymbols[weekday], hour: hour,
                    commits: commits, level: level(commits))
            }
        }
    }

    private struct DateResolver {
        let calendar: Calendar

        func date(_ day: String) -> Date? {
            guard let parts = CodeStatsDay(day)?.components else { return nil }
            return calendar.date(
                from: DateComponents(year: parts.year, month: parts.month, day: parts.day))
        }
    }
}
