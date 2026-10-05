import Foundation

public enum CodeStatsReportBuilder {
    public static let topSeriesCount = 5
    public static let topDayCount = 10
    public static let weeklyRollingWindow = 4
    public static let monthlyRollingWindow = 3

    public struct Entry: Sendable {
        public let day: CodeStatsDay
        public let hour: Int
        public let repository: Int
        public let language: Int
        public let commits: Int
        public let counts: CodeStatsLanguageCounts
    }

    private struct Bucket {
        var commits = 0
        var counts = CodeStatsLanguageCounts()

        mutating func add(_ entry: Entry) {
            commits += entry.commits
            counts.add(entry.counts)
        }
    }

    public static func build(
        commits: [CodeStatsCommit], range: CodeStatsRange, today: Date, calendar: Calendar
    ) -> CodeStatsReport {
        build(
            table: CodeStatsFactBuilder.build(commits: commits), filter: .default, range: range,
            today: today, calendar: calendar)
    }

    public static func build(
        table: CodeStatsFactTable, filter: CodeStatsFilter, range: CodeStatsRange, today: Date,
        calendar: Calendar
    ) -> CodeStatsReport {
        let all = entries(table, filter: filter)
        var end = CodeStatsDay(date: today, calendar: calendar)
        let length: Int
        switch range {
        case .days(let count): length = max(count, 1)
        case .year: length = 365
        case .all: length = max((all.map(\.day).min()?.distance(to: end) ?? 0) + 1, 1)
        case .between(let first, let last):
            let lower = CodeStatsDay(first) ?? end
            end = CodeStatsDay(last) ?? end
            length = max(lower.distance(to: end) + 1, 1)
        }
        let start = end.advanced(by: -(length - 1))
        let selected = all.filter { $0.day >= start && $0.day <= end }
        var days = [Bucket](repeating: Bucket(), count: length)
        for entry in selected { days[start.distance(to: entry.day)].add(entry) }
        let daily = days.enumerated().map { offset, bucket in
            CodeStatsDayPoint(
                day: start.advanced(by: offset).string, commits: bucket.commits,
                counts: bucket.counts)
        }
        let firstWeekday = calendar.firstWeekday
        let summaries = repositories(
            selected, names: table.repositories, languages: table.languages)
        let languageTotals = languages(selected, names: table.languages)
        return CodeStatsReport(
            range: range, startDay: start.string, endDay: end.string,
            totals: totals(selected, all, days: days, start: start, end: end),
            momentum: range == .all
                ? nil : momentum(selected, all, start: start, length: length),
            daily: daily,
            weekly: periods(
                days, start: start, from: start.weekStart(firstWeekday: firstWeekday), to: end,
                window: weeklyRollingWindow, next: { $0.advanced(by: 7) },
                key: { $0.weekStart(firstWeekday: firstWeekday) }),
            monthly: periods(
                days, start: start, from: start.monthStart, to: end,
                window: monthlyRollingWindow, next: \.nextMonthStart, key: \.monthStart),
            repositories: summaries,
            repositoryMonthly: repositoryMonthly(
                selected, top: summaries.prefix(topSeriesCount).map(\.repository),
                names: table.repositories, start: start, end: end),
            languages: languageTotals,
            languageMonthly: languageMonthly(
                selected, top: languageTotals.prefix(topSeriesCount).map(\.language),
                names: table.languages, start: start, end: end),
            punchcard: punchcard(selected),
            topDays: daily.filter { $0.commits > 0 }.sorted {
                ($0.counts.authored, $0.commits, $0.day) > ($1.counts.authored, $1.commits, $1.day)
            }.prefix(topDayCount).map { $0 })
    }

    public static func entries(
        _ table: CodeStatsFactTable, filter: CodeStatsFilter
    ) -> [Entry] {
        let repositoryAllowed = table.repositories.map { name in
            !filter.excludedRepositories.contains(name)
                && (filter.repositories.isEmpty || filter.repositories.contains(name))
                && (filter.owners.isEmpty
                    || filter.owners.contains(
                        name.split(separator: "/", maxSplits: 1).first.map(String.init) ?? name))
        }
        let languageAllowed = table.languages.map {
            filter.languages.isEmpty || filter.languages.contains($0)
        }
        let excludedCommits = filter.excludedCommitFlags
        let excludedLines = filter.excludedLineFlags
        var result: [Entry] = []
        result.reserveCapacity(table.rows.count)
        for row in table.rows {
            guard repositoryAllowed.indices.contains(row.repository),
                repositoryAllowed[row.repository],
                languageAllowed.indices.contains(row.language)
                    ? languageAllowed[row.language] : filter.languages.isEmpty,
                row.flags.isDisjoint(with: excludedCommits)
            else { continue }
            let counted =
                filter.categories.contains(row.category)
                && row.flags.isDisjoint(with: excludedLines)
            let counts = counted ? row.counts : .zero
            guard row.commits > 0 || !counts.isEmpty else { continue }
            result.append(
                Entry(
                    day: CodeStatsDay(ordinal: row.day), hour: row.hour,
                    repository: row.repository, language: row.language, commits: row.commits,
                    counts: counts))
        }
        return result
    }

    private static func totals(
        _ selected: [Entry], _ all: [Entry], days: [Bucket], start: CodeStatsDay,
        end: CodeStatsDay
    ) -> CodeStatsTotals {
        let bucket = selected.reduce(into: Bucket()) { $0.add($1) }
        let activeDays = days.filter { $0.commits > 0 }.count
        let streaks = streaks(
            activeDays: Set(all.lazy.filter { $0.commits > 0 }.map(\.day)), start: start, end: end)
        return CodeStatsTotals(
            commits: bucket.commits, authored: bucket.counts.authored,
            added: bucket.counts.added, updated: bucket.counts.updated,
            deleted: bucket.counts.deleted, net: bucket.counts.net, activeDays: activeDays,
            repositories: Set(selected.lazy.filter { $0.commits > 0 }.map(\.repository)).count,
            currentStreak: streaks.current, longestStreak: streaks.longest,
            averagePerActiveDay: activeDays == 0
                ? 0 : Double(bucket.counts.authored) / Double(activeDays))
    }

    static func streaks(
        activeDays: Set<CodeStatsDay>, start: CodeStatsDay, end: CodeStatsDay
    ) -> (current: Int, longest: Int) {
        var current = 0
        var cursor = activeDays.contains(end) ? end : end.advanced(by: -1)
        while activeDays.contains(cursor) {
            current += 1
            cursor = cursor.advanced(by: -1)
        }
        var longest = current
        var runStart: CodeStatsDay?
        var previous: CodeStatsDay?
        for day in activeDays.sorted() {
            if previous?.advanced(by: 1) != day { runStart = day }
            if let runStart, day >= start, runStart <= end {
                longest = max(longest, runStart.distance(to: day) + 1)
            }
            previous = day
        }
        return (current, longest)
    }

    private static func momentum(
        _ selected: [Entry], _ all: [Entry], start: CodeStatsDay, length: Int
    ) -> CodeStatsMomentum {
        let previousStart = start.advanced(by: -length)
        let previous = all.lazy.filter { $0.day >= previousStart && $0.day < start }
            .reduce(into: Bucket()) { $0.add($1) }
        let current = selected.reduce(into: Bucket()) { $0.add($1) }
        return CodeStatsMomentum(
            commits: current.commits, previousCommits: previous.commits,
            lines: current.counts.authored, previousLines: previous.counts.authored)
    }

    private static func periodStarts(
        from first: CodeStatsDay, to end: CodeStatsDay, next: (CodeStatsDay) -> CodeStatsDay
    ) -> [CodeStatsDay] {
        var starts: [CodeStatsDay] = []
        var cursor = first
        while cursor <= end {
            starts.append(cursor)
            cursor = next(cursor)
        }
        return starts
    }

    private static func periods(
        _ days: [Bucket], start: CodeStatsDay, from first: CodeStatsDay, to end: CodeStatsDay,
        window: Int, next: (CodeStatsDay) -> CodeStatsDay, key: (CodeStatsDay) -> CodeStatsDay
    ) -> [CodeStatsPeriodPoint] {
        var buckets: [CodeStatsDay: Bucket] = [:]
        for (offset, day) in days.enumerated() where day.commits > 0 || !day.counts.isEmpty {
            let period = key(start.advanced(by: offset))
            buckets[period, default: Bucket()].commits += day.commits
            buckets[period, default: Bucket()].counts.add(day.counts)
        }
        let values = periodStarts(from: first, to: end, next: next).map {
            ($0, buckets[$0] ?? Bucket())
        }
        return values.indices.map { index in
            let trailing = values[max(0, index - window + 1)...index]
            let size = Double(trailing.count)
            return CodeStatsPeriodPoint(
                start: values[index].0.string, commits: values[index].1.commits,
                lines: values[index].1.counts.authored,
                rollingCommits: Double(trailing.reduce(0) { $0 + $1.1.commits }) / size,
                rollingLines: Double(trailing.reduce(0) { $0 + $1.1.counts.authored }) / size)
        }
    }

    private static func repositories(
        _ selected: [Entry], names: [String], languages: [String]
    ) -> [CodeStatsRepositorySummary] {
        struct Accumulator {
            var bucket = Bucket()
            var first: CodeStatsDay?
            var last: CodeStatsDay?
            var days = Set<CodeStatsDay>()
            var languages: [Int: Int] = [:]
        }
        var accumulators = [Accumulator](repeating: Accumulator(), count: names.count)
        for entry in selected where accumulators.indices.contains(entry.repository) {
            let index = entry.repository
            accumulators[index].bucket.add(entry)
            accumulators[index].first = min(accumulators[index].first ?? entry.day, entry.day)
            accumulators[index].last = max(accumulators[index].last ?? entry.day, entry.day)
            if entry.commits > 0 { accumulators[index].days.insert(entry.day) }
            if entry.language >= 0, entry.counts.authored > 0 {
                accumulators[index].languages[entry.language, default: 0] += entry.counts.authored
            }
        }
        return accumulators.enumerated().compactMap {
            index, accumulator -> CodeStatsRepositorySummary? in
            guard accumulator.bucket.commits > 0 else { return nil }
            let top = accumulator.languages.max {
                ($0.value, languages[$1.key]) < ($1.value, languages[$0.key])
            }
            return CodeStatsRepositorySummary(
                repository: names[index], commits: accumulator.bucket.commits,
                counts: accumulator.bucket.counts, firstDay: accumulator.first?.string ?? "",
                lastDay: accumulator.last?.string ?? "", activeDays: accumulator.days.count,
                topLanguage: top.flatMap {
                    languages.indices.contains($0.key) ? languages[$0.key] : nil
                })
        }.sorted { ($0.commits, $1.repository) > ($1.commits, $0.repository) }
    }

    private static func repositoryMonthly(
        _ selected: [Entry], top: [String], names: [String], start: CodeStatsDay,
        end: CodeStatsDay
    ) -> [CodeStatsSeries] {
        let months = periodStarts(from: start.monthStart, to: end, next: \.nextMonthStart)
        return top.map { repository in
            let index = names.firstIndex(of: repository) ?? -1
            var counts: [CodeStatsDay: Int] = [:]
            for entry in selected where entry.repository == index {
                counts[entry.day.monthStart, default: 0] += entry.commits
            }
            return CodeStatsSeries(
                name: repository,
                values: months.map {
                    CodeStatsSeriesValue(start: $0.string, value: Double(counts[$0] ?? 0))
                })
        }
    }

    private static func languages(_ selected: [Entry], names: [String]) -> [CodeStatsLanguageTotal]
    {
        var totals = [CodeStatsLanguageCounts](repeating: .zero, count: names.count)
        for entry in selected where totals.indices.contains(entry.language) {
            totals[entry.language].add(entry.counts)
        }
        let authored = Double(totals.reduce(0) { $0 + $1.authored })
        return totals.enumerated().compactMap { index, counts in
            counts.isEmpty
                ? nil
                : CodeStatsLanguageTotal(
                    language: names[index], counts: counts,
                    share: authored == 0 ? 0 : Double(counts.authored) / authored)
        }.sorted { ($0.counts.authored, $1.language) > ($1.counts.authored, $0.language) }
    }

    private static func languageMonthly(
        _ selected: [Entry], top: [String], names: [String], start: CodeStatsDay,
        end: CodeStatsDay
    ) -> [CodeStatsSeries] {
        let months = periodStarts(from: start.monthStart, to: end, next: \.nextMonthStart)
        let indices = top.map { names.firstIndex(of: $0) ?? -1 }
        var monthTotals: [CodeStatsDay: Int] = [:]
        var languageTotals: [CodeStatsDay: [Int: Int]] = [:]
        for entry in selected where entry.language >= 0 && entry.counts.authored > 0 {
            let month = entry.day.monthStart
            monthTotals[month, default: 0] += entry.counts.authored
            if indices.contains(entry.language) {
                languageTotals[month, default: [:]][entry.language, default: 0] +=
                    entry.counts.authored
            }
        }
        return zip(top, indices).map { language, index in
            CodeStatsSeries(
                name: language,
                values: months.map { month in
                    let total = monthTotals[month] ?? 0
                    let share =
                        total == 0
                        ? 0 : Double(languageTotals[month]?[index] ?? 0) / Double(total)
                    return CodeStatsSeriesValue(start: month.string, value: share)
                })
        }
    }

    private static func punchcard(_ selected: [Entry]) -> [[Int]] {
        var grid = Array(repeating: Array(repeating: 0, count: 24), count: 7)
        for entry in selected where entry.commits > 0 {
            grid[entry.day.weekdayIndex][min(max(entry.hour, 0), 23)] += entry.commits
        }
        return grid
    }
}
