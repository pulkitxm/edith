import Foundation

public enum CodeStatsReportBuilder {
    public static let topSeriesCount = 5
    public static let topDayCount = 10
    public static let weeklyRollingWindow = 4
    public static let monthlyRollingWindow = 3

    private struct Bucket {
        var commits = 0
        var counts = CodeStatsLanguageCounts()

        mutating func add(_ commit: CodeStatsCommit) {
            commits += 1
            counts.add(commit.totals)
        }
    }

    private struct Dated {
        let commit: CodeStatsCommit
        let day: CodeStatsDay
    }

    public static func deduplicated(_ commits: [CodeStatsCommit]) -> [CodeStatsCommit] {
        var seen = Set<String>()
        return commits.filter { seen.insert($0.sha).inserted }
    }

    public static func build(
        commits: [CodeStatsCommit], range: CodeStatsRange, today: Date, calendar: Calendar
    ) -> CodeStatsReport {
        let dated = deduplicated(commits).compactMap { commit in
            CodeStatsDay(commit.day).map { Dated(commit: commit, day: $0) }
        }
        let end = CodeStatsDay(date: today, calendar: calendar)
        let length: Int
        switch range {
        case .days(let count): length = max(count, 1)
        case .year: length = 365
        case .all: length = max((dated.map(\.day).min()?.distance(to: end) ?? 0) + 1, 1)
        }
        let start = end.advanced(by: -(length - 1))
        let selected = dated.filter { $0.day >= start && $0.day <= end }
        let days = Dictionary(grouping: selected, by: \.day).mapValues(bucket)
        let daily = (start...end).map { point($0, days[$0] ?? Bucket()) }
        let momentum: CodeStatsMomentum? =
            range == .all
            ? nil
            : previousMomentum(selected, dated, start: start, length: length)
        let firstWeekday = calendar.firstWeekday
        return CodeStatsReport(
            range: range, startDay: start.string, endDay: end.string,
            totals: totals(selected, dated, days: days, start: start, end: end),
            momentum: momentum,
            daily: daily,
            weekly: periods(
                selected, from: start.weekStart(firstWeekday: firstWeekday), to: end,
                window: weeklyRollingWindow, next: { $0.advanced(by: 7) },
                key: { $0.weekStart(firstWeekday: firstWeekday) }),
            monthly: periods(
                selected, from: start.monthStart, to: end, window: monthlyRollingWindow,
                next: \.nextMonthStart, key: \.monthStart),
            repositories: repositories(selected),
            repositoryMonthly: repositoryMonthly(selected, start: start, end: end),
            languages: languages(selected),
            languageMonthly: languageMonthly(selected, start: start, end: end),
            punchcard: punchcard(selected),
            topDays: daily.filter { $0.commits > 0 }.sorted {
                ($0.counts.authored, $0.commits, $0.day) > ($1.counts.authored, $1.commits, $1.day)
            }.prefix(topDayCount).map { $0 })
    }

    private static func bucket(_ entries: [Dated]) -> Bucket {
        entries.reduce(into: Bucket()) { $0.add($1.commit) }
    }

    private static func point(_ day: CodeStatsDay, _ bucket: Bucket) -> CodeStatsDayPoint {
        CodeStatsDayPoint(day: day.string, commits: bucket.commits, counts: bucket.counts)
    }

    private static func totals(
        _ selected: [Dated], _ all: [Dated], days: [CodeStatsDay: Bucket], start: CodeStatsDay,
        end: CodeStatsDay
    ) -> CodeStatsTotals {
        let counts = selected.reduce(into: CodeStatsLanguageCounts()) { $0.add($1.commit.totals) }
        let streaks = streaks(activeDays: Set(all.map(\.day)), start: start, end: end)
        return CodeStatsTotals(
            commits: selected.count, authored: counts.authored, added: counts.added,
            updated: counts.updated, deleted: counts.deleted, net: counts.net,
            activeDays: days.count,
            repositories: Set(selected.map(\.commit.repository)).count,
            currentStreak: streaks.current, longestStreak: streaks.longest,
            averagePerActiveDay: days.isEmpty ? 0 : Double(counts.authored) / Double(days.count))
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

    private static func previousMomentum(
        _ selected: [Dated], _ all: [Dated], start: CodeStatsDay, length: Int
    ) -> CodeStatsMomentum {
        let previousStart = start.advanced(by: -length)
        let previous = all.filter { $0.day >= previousStart && $0.day < start }
        return CodeStatsMomentum(
            commits: selected.count, previousCommits: previous.count,
            lines: selected.reduce(0) { $0 + $1.commit.totals.authored },
            previousLines: previous.reduce(0) { $0 + $1.commit.totals.authored })
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
        _ selected: [Dated], from first: CodeStatsDay, to end: CodeStatsDay, window: Int,
        next: (CodeStatsDay) -> CodeStatsDay, key: (CodeStatsDay) -> CodeStatsDay
    ) -> [CodeStatsPeriodPoint] {
        let buckets = Dictionary(grouping: selected) { key($0.day) }.mapValues(bucket)
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

    private static func repositories(_ selected: [Dated]) -> [CodeStatsRepositorySummary] {
        Dictionary(grouping: selected, by: \.commit.repository).map { name, entries in
            var languages: [String: Int] = [:]
            for entry in entries {
                for (language, counts) in entry.commit.languages {
                    languages[language, default: 0] += counts.authored
                }
            }
            let days = entries.map(\.day)
            return CodeStatsRepositorySummary(
                repository: name, commits: entries.count,
                counts: entries.reduce(into: CodeStatsLanguageCounts()) {
                    $0.add($1.commit.totals)
                },
                firstDay: days.min()?.string ?? "", lastDay: days.max()?.string ?? "",
                activeDays: Set(days).count,
                topLanguage: languages.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key)
        }.sorted { ($0.commits, $1.repository) > ($1.commits, $0.repository) }
    }

    private static func repositoryMonthly(
        _ selected: [Dated], start: CodeStatsDay, end: CodeStatsDay
    ) -> [CodeStatsSeries] {
        let months = periodStarts(from: start.monthStart, to: end, next: \.nextMonthStart)
        return repositories(selected).prefix(topSeriesCount).map { summary in
            let entries = selected.filter { $0.commit.repository == summary.repository }
            let counts = Dictionary(grouping: entries, by: \.day.monthStart).mapValues(\.count)
            return CodeStatsSeries(
                name: summary.repository,
                values: months.map {
                    CodeStatsSeriesValue(start: $0.string, value: Double(counts[$0] ?? 0))
                })
        }
    }

    private static func languageCounts(_ entries: [Dated]) -> [String: CodeStatsLanguageCounts] {
        var totals: [String: CodeStatsLanguageCounts] = [:]
        for entry in entries {
            for (language, counts) in entry.commit.languages {
                totals[language, default: .zero].add(counts)
            }
        }
        return totals
    }

    private static func languages(_ selected: [Dated]) -> [CodeStatsLanguageTotal] {
        let totals = languageCounts(selected)
        let authored = Double(totals.values.reduce(0) { $0 + $1.authored })
        return totals.map { language, counts in
            CodeStatsLanguageTotal(
                language: language, counts: counts,
                share: authored == 0 ? 0 : Double(counts.authored) / authored)
        }.sorted { ($0.counts.authored, $1.language) > ($1.counts.authored, $0.language) }
    }

    private static func languageMonthly(
        _ selected: [Dated], start: CodeStatsDay, end: CodeStatsDay
    ) -> [CodeStatsSeries] {
        let months = periodStarts(from: start.monthStart, to: end, next: \.nextMonthStart)
        let byMonth = Dictionary(grouping: selected, by: \.day.monthStart).mapValues(
            languageCounts)
        return languages(selected).prefix(topSeriesCount).map { total in
            CodeStatsSeries(
                name: total.language,
                values: months.map { month in
                    let counts = byMonth[month] ?? [:]
                    let monthTotal = counts.values.reduce(0) { $0 + $1.authored }
                    let share =
                        monthTotal == 0
                        ? 0 : Double(counts[total.language]?.authored ?? 0) / Double(monthTotal)
                    return CodeStatsSeriesValue(start: month.string, value: share)
                })
        }
    }

    private static func punchcard(_ selected: [Dated]) -> [[Int]] {
        var grid = Array(repeating: Array(repeating: 0, count: 24), count: 7)
        for entry in selected {
            grid[entry.day.weekdayIndex][min(max(entry.commit.hour, 0), 23)] += 1
        }
        return grid
    }
}
