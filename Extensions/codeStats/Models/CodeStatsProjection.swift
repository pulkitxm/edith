import EdithExtensionSupport
import EdithExtensionUI
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
    case hourly
    case daily
    case weekly
    case monthly

    var unit: Calendar.Component {
        switch self {
        case .hourly: .hour
        case .daily: .day
        case .weekly: .weekOfYear
        case .monthly: .month
        }
    }

    var barsTitle: String {
        switch self {
        case .hourly: "Hourly"
        case .daily: "Daily"
        case .weekly: "Weekly"
        case .monthly: "Monthly"
        }
    }
}

struct CodeStatsProjection: Equatable, Sendable {
    static let heatmapDays = 371
    static let repositoryBarCount = 10
    static let languageShareCount = 8
    static let monthlyTrendThreshold = 104
    static let dailyTrendDays = 31
    static let dailyRollingWindow = 7
    static let contributionWeeks = 5

    var heatWeeks: [CodeStatsHeatWeek] = []
    var dayCount = 0
    var trendGranularity = CodeStatsTrendGranularity.weekly
    var trend: [CodeStatsTrendPoint] = []
    var repositoryBars: [CodeStatsRepositorySummary] = []
    var repositoryRows: [CodeStatsRepositorySort: [CodeStatsRepositorySummary]] = [:]
    var stackGranularity = CodeStatsTrendGranularity.monthly
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
        dayCount = report.daily.count
        heatWeeks = Self.heatWeeks(report.daily, calendar: calendar, dates: dates)
        let trendSource = Self.trendSource(report, dates: dates, calendar: calendar)
        trendGranularity = trendSource.granularity
        var runningCommits = 0
        var runningLines = 0
        var points: [CodeStatsTrendPoint] = []
        for var point in trendSource.points {
            runningCommits += point.commits
            runningLines += point.lines
            point.totalCommits = runningCommits
            point.totalLines = runningLines
            points.append(point)
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
        stackGranularity = Self.stackGranularity(report)
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

    var isSingleDay: Bool { dayCount == 1 }

    var showsContributions: Bool { heatWeeks.count >= Self.contributionWeeks }

    var showsStackedTrend: Bool {
        Set((repositoryMonthly + languageMonthly).map(\.date)).count > 1
    }

    private static func trendSource(
        _ report: CodeStatsReport, dates: DateResolver, calendar: Calendar
    ) -> (granularity: CodeStatsTrendGranularity, points: [CodeStatsTrendPoint]) {
        if let hourly = report.hourly, let day = dates.date(report.startDay) {
            return (
                .hourly,
                hourly.compactMap { hour in
                    calendar.date(byAdding: .hour, value: hour.hour, to: day).map {
                        CodeStatsTrendPoint(
                            date: $0, commits: hour.commits, lines: hour.lines,
                            rollingCommits: 0, rollingLines: 0)
                    }
                }
            )
        }
        if report.daily.count <= dailyTrendDays {
            return (.daily, dailyPoints(report.daily, dates: dates))
        }
        let useMonthly = report.weekly.count > monthlyTrendThreshold
        return (
            useMonthly ? .monthly : .weekly,
            (useMonthly ? report.monthly : report.weekly).compactMap { point in
                dates.date(point.start).map {
                    CodeStatsTrendPoint(
                        date: $0, commits: point.commits, lines: point.lines,
                        rollingCommits: point.rollingCommits, rollingLines: point.rollingLines)
                }
            }
        )
    }

    private static func dailyPoints(
        _ daily: [CodeStatsDayPoint], dates: DateResolver
    ) -> [CodeStatsTrendPoint] {
        daily.indices.compactMap { index in
            let trailing = daily[max(0, index - dailyRollingWindow + 1)...index]
            let size = Double(trailing.count)
            return dates.date(daily[index].day).map {
                CodeStatsTrendPoint(
                    date: $0, commits: daily[index].commits, lines: daily[index].counts.authored,
                    rollingCommits: Double(trailing.reduce(0) { $0 + $1.commits }) / size,
                    rollingLines: Double(trailing.reduce(0) { $0 + $1.counts.authored }) / size)
            }
        }
    }

    private static func stackGranularity(_ report: CodeStatsReport) -> CodeStatsTrendGranularity {
        let values = (report.repositoryMonthly + report.languageMonthly).first?.values ?? []
        guard values.count > 1, let first = CodeStatsDay(values[0].start),
            let second = CodeStatsDay(values[1].start)
        else { return .monthly }
        return first.distance(to: second) == 1 ? .daily : .monthly
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
