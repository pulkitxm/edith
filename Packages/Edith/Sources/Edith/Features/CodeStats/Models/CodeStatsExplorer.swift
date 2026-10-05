import EdithKit
import Foundation

struct CodeStatsStripCell: Identifiable, Equatable, Sendable {
    var id: String { repository + "|" + month }
    let repository: String
    let month: String
    let date: Date
    let commits: Int
    let lines: Int
    let level: Double
}

struct CodeStatsStripMonth: Identifiable, Equatable, Sendable {
    var id: String { month }
    let month: String
    let date: Date
}

struct CodeStatsYearPoint: Identifiable, Equatable, Sendable {
    var id: String { year + "|" + String(month) }
    let year: String
    let month: Int
    let commits: Int
    let lines: Int
}

struct CodeStatsRhythmBar: Identifiable, Equatable, Sendable {
    var id: Int { index }
    let index: Int
    let label: String
    let commits: Int
    let lines: Int
}

struct CodeStatsSlice: Identifiable, Equatable, Sendable {
    var id: String { name }
    let name: String
    let commits: Int
    let lines: Int
    let share: Double
    let isOther: Bool
}

struct CodeStatsMonthCount: Identifiable, Equatable, Sendable {
    var id: Date { date }
    let date: Date
    let count: Int
    let names: [String]
}

struct CodeStatsDayShare: Equatable, Sendable {
    let name: String
    let commits: Int
    let lines: Int
}

struct CodeStatsDayDetail: Equatable, Sendable {
    let commits: Int
    let lines: Int
    let repositories: [CodeStatsDayShare]
    let languages: [CodeStatsDayShare]
}

struct CodeStatsDominance: Equatable, Sendable {
    let repository: String
    let share: Double
}

struct CodeStatsExplorer: Equatable, Sendable {
    static let stripRepositories = 15
    static let sliceCount = 7
    static let dominantShare = 0.4

    var strip: [CodeStatsStripCell] = []
    var stripRepositories: [String] = []
    var stripMonths: [CodeStatsStripMonth] = []
    var stripCells: [String: CodeStatsStripCell] = [:]
    var years: [CodeStatsYearPoint] = []
    var yearNames: [String] = []
    var weekdays: [CodeStatsRhythmBar] = []
    var hours: [CodeStatsRhythmBar] = []
    var owners: [CodeStatsSlice] = []
    var repositories: [CodeStatsSlice] = []
    var newRepositories: [CodeStatsMonthCount] = []
    var dominant: CodeStatsDominance?
    var days: [String: CodeStatsDayDetail] = [:]

    static let dayShares = 4

    init() {}

    init(
        table: CodeStatsFactTable, filter: CodeStatsFilter, startDay: String, endDay: String,
        calendar: Calendar
    ) {
        let all = CodeStatsReportBuilder.entries(table, filter: filter)
        let start = CodeStatsDay(startDay) ?? CodeStatsDay(ordinal: Int.min / 2)
        let end = CodeStatsDay(endDay) ?? CodeStatsDay(ordinal: Int.max / 2)
        let names = table.repositories
        var perRepository = [(commits: Int, lines: Int)](repeating: (0, 0), count: names.count)
        var perMonth: [Int: [Int: (commits: Int, lines: Int)]] = [:]
        var perYearMonth: [Int: [Int: (commits: Int, lines: Int)]] = [:]
        var weekdayTotals = [(commits: Int, lines: Int)](repeating: (0, 0), count: 7)
        var hourTotals = [(commits: Int, lines: Int)](repeating: (0, 0), count: 24)
        var firstMonth = [Int: CodeStatsDay]()
        var total = 0
        var dayRepositories: [Int: [Int: (commits: Int, lines: Int)]] = [:]
        var dayLanguages: [Int: [Int: (commits: Int, lines: Int)]] = [:]
        for entry in all {
            let lines = entry.counts.added + entry.counts.updated
            if entry.commits > 0, names.indices.contains(entry.repository) {
                let month = entry.day.monthStart
                if let known = firstMonth[entry.repository] {
                    if month < known { firstMonth[entry.repository] = month }
                } else {
                    firstMonth[entry.repository] = month
                }
            }
            let parts = entry.day.components
            perYearMonth[parts.year, default: [:]][parts.month, default: (0, 0)].commits +=
                entry.commits
            perYearMonth[parts.year, default: [:]][parts.month, default: (0, 0)].lines += lines
            guard entry.day >= start, entry.day <= end else { continue }
            total += lines
            dayRepositories[entry.day.ordinal, default: [:]][entry.repository, default: (0, 0)]
                .commits += entry.commits
            dayRepositories[entry.day.ordinal, default: [:]][entry.repository, default: (0, 0)]
                .lines += lines
            dayLanguages[entry.day.ordinal, default: [:]][entry.language, default: (0, 0)]
                .commits += entry.commits
            dayLanguages[entry.day.ordinal, default: [:]][entry.language, default: (0, 0)]
                .lines += lines
            if names.indices.contains(entry.repository) {
                perRepository[entry.repository].commits += entry.commits
                perRepository[entry.repository].lines += lines
                perMonth[entry.repository, default: [:]][
                    entry.day.monthStart.ordinal, default: (0, 0)
                ].commits += entry.commits
                perMonth[entry.repository, default: [:]][
                    entry.day.monthStart.ordinal, default: (0, 0)
                ].lines += lines
            }
            weekdayTotals[entry.day.weekdayIndex].commits += entry.commits
            weekdayTotals[entry.day.weekdayIndex].lines += lines
            if hourTotals.indices.contains(entry.hour) {
                hourTotals[entry.hour].commits += entry.commits
                hourTotals[entry.hour].lines += lines
            }
        }
        var details: [String: CodeStatsDayDetail] = [:]
        for (ordinal, repositories) in dayRepositories {
            let languages = dayLanguages[ordinal] ?? [:]
            details[CodeStatsDay(ordinal: ordinal).string] = CodeStatsDayDetail(
                commits: repositories.values.reduce(0) { $0 + $1.commits },
                lines: repositories.values.reduce(0) { $0 + $1.lines },
                repositories: Self.shares(repositories, names: names),
                languages: Self.shares(languages, names: table.languages))
        }
        days = details
        let resolver = Self.dateResolver(calendar)
        let ranked = names.indices.filter { perRepository[$0].commits > 0 }.sorted {
            (perRepository[$0].commits, names[$1]) > (perRepository[$1].commits, names[$0])
        }
        let shown = Array(ranked.prefix(Self.stripRepositories))
        stripRepositories = shown.map { names[$0] }
        var cells: [CodeStatsStripCell] = []
        for index in shown {
            let months = perMonth[index] ?? [:]
            let peak = max(months.values.map(\.commits).max() ?? 0, 1)
            for (ordinal, value) in months where value.commits > 0 {
                let day = CodeStatsDay(ordinal: ordinal)
                guard let date = resolver(day) else { continue }
                cells.append(
                    CodeStatsStripCell(
                        repository: names[index], month: day.string, date: date,
                        commits: value.commits, lines: value.lines,
                        level: Double(value.commits) / Double(peak)))
            }
        }
        strip = cells
        stripCells = Dictionary(cells.map { ($0.id, $0) }) { first, _ in first }
        if let firstCell = cells.map(\.month).min(), let lastCell = cells.map(\.month).max(),
            var cursor = CodeStatsDay(firstCell), let limit = CodeStatsDay(lastCell)
        {
            var months: [CodeStatsStripMonth] = []
            while cursor <= limit {
                if let date = resolver(cursor) {
                    months.append(CodeStatsStripMonth(month: cursor.string, date: date))
                }
                cursor = cursor.nextMonthStart
            }
            stripMonths = months
        }
        let sortedYears = perYearMonth.keys.sorted().suffix(4)
        yearNames = sortedYears.map(String.init)
        let last = end.ordinal < Int.max / 4 ? end.components : (year: Int.max, month: 12, day: 31)
        years = sortedYears.flatMap { year in
            (1...(year == last.year ? last.month : 12)).map { month in
                let value = perYearMonth[year]?[month] ?? (0, 0)
                return CodeStatsYearPoint(
                    year: String(year), month: month, commits: value.commits, lines: value.lines)
            }
        }
        let weekdayNames = calendar.shortWeekdaySymbols
        let order = (0..<7).map { (calendar.firstWeekday - 1 + $0) % 7 }
        weekdays = order.map { index in
            CodeStatsRhythmBar(
                index: index,
                label: weekdayNames.indices.contains(index) ? weekdayNames[index] : String(index),
                commits: weekdayTotals[index].commits, lines: weekdayTotals[index].lines)
        }
        hours = (0..<24).map { hour in
            CodeStatsRhythmBar(
                index: hour, label: String(format: "%02d", hour),
                commits: hourTotals[hour].commits, lines: hourTotals[hour].lines)
        }
        var ownerTotals: [String: (commits: Int, lines: Int)] = [:]
        for index in ranked {
            let owner = Self.owner(names[index])
            ownerTotals[owner, default: (0, 0)].commits += perRepository[index].commits
            ownerTotals[owner, default: (0, 0)].lines += perRepository[index].lines
        }
        owners = Self.slices(
            ownerTotals.map { ($0.key, $0.value.commits, $0.value.lines) }, total: total)
        repositories = Self.slices(
            ranked.map { (names[$0], perRepository[$0].commits, perRepository[$0].lines) },
            total: total)
        if let top = ranked.max(by: { perRepository[$0].lines < perRepository[$1].lines }),
            total > 0
        {
            let share = Double(perRepository[top].lines) / Double(total)
            if share >= Self.dominantShare, ranked.count > 1 {
                dominant = CodeStatsDominance(repository: names[top], share: share)
            }
        }
        var started: [Int: [String]] = [:]
        for (index, month) in firstMonth where month >= start.monthStart && month <= end {
            started[month.ordinal, default: []].append(names[index])
        }
        newRepositories = started.keys.sorted().compactMap { ordinal in
            guard let date = resolver(CodeStatsDay(ordinal: ordinal)) else { return nil }
            let list = (started[ordinal] ?? []).sorted()
            return CodeStatsMonthCount(date: date, count: list.count, names: list)
        }
    }

    static func shares(
        _ values: [Int: (commits: Int, lines: Int)], names: [String]
    ) -> [CodeStatsDayShare] {
        values.compactMap { index, value -> CodeStatsDayShare? in
            guard names.indices.contains(index), value.commits > 0 || value.lines > 0 else {
                return nil
            }
            return CodeStatsDayShare(name: names[index], commits: value.commits, lines: value.lines)
        }
        .sorted { ($0.lines, $0.commits, $1.name) > ($1.lines, $1.commits, $0.name) }
        .prefix(dayShares).map { $0 }
    }

    static func owner(_ repository: String) -> String {
        repository.split(separator: "/", maxSplits: 1).first.map(String.init) ?? repository
    }

    static func slices(_ values: [(String, Int, Int)], total: Int) -> [CodeStatsSlice] {
        let sorted = values.filter { $0.2 > 0 || $0.1 > 0 }.sorted {
            ($0.2, $0.1, $1.0) > ($1.2, $1.1, $0.0)
        }
        let denominator = Double(max(total, 1))
        var result = sorted.prefix(sliceCount).map {
            CodeStatsSlice(
                name: $0.0, commits: $0.1, lines: $0.2, share: Double($0.2) / denominator,
                isOther: false)
        }
        let rest = sorted.dropFirst(sliceCount)
        if !rest.isEmpty {
            let lines = rest.reduce(0) { $0 + $1.2 }
            result.append(
                CodeStatsSlice(
                    name: "Other (\(rest.count))", commits: rest.reduce(0) { $0 + $1.1 },
                    lines: lines, share: Double(lines) / denominator, isOther: true))
        }
        return result
    }

    static func dateResolver(_ calendar: Calendar) -> (CodeStatsDay) -> Date? {
        { day in
            let parts = day.components
            return calendar.date(
                from: DateComponents(year: parts.year, month: parts.month, day: parts.day))
        }
    }
}
