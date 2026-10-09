import EdithExtensionSupport
import Foundation

public struct SurfaceUsageDocument: Decodable, Sendable {
    public let generatedAt: String?
    public let defaultSources: [String]?
    public let sourceMeta: [String: Source]?
    public let daily: [Day]

    public struct Source: Decodable, Sendable {
        public let label: String?
    }

    public struct Day: Decodable, Sendable {
        public let period: String
        public let bySource: [String: [Model]]?
    }

    public struct Model: Decodable, Sendable {
        public let modelName: String?
        public let inputTokens: Double?
        public let outputTokens: Double?
        public let cacheCreationTokens: Double?
        public let cacheReadTokens: Double?
        public let cost: Double?
        public let costMissing: Bool?
        public let unpricedTokens: Double?
        public var tokens: Double {
            [inputTokens, outputTokens, cacheCreationTokens, cacheReadTokens].reduce(0) {
                min(1e15, $0 + SurfaceUsageSnapshot.valid($1))
            }
        }
    }
}

public struct SurfaceUsageSnapshot: Sendable {
    public struct Total: Sendable {
        public var cost = 0.0
        public var tokens = 0.0
        mutating func add(cost: Double, tokens: Double) {
            self.cost = min(1e15, self.cost + cost); self.tokens = min(1e15, self.tokens + tokens)
        }
    }
    public struct Breakdown: Identifiable, Sendable {
        public let id: String
        public let title: String
        public let total: Total
    }
    public let today: Total
    public let week: Total
    public let total: Total
    public let days: [DayPoint]
    public let providers: [Breakdown]
    public let models: [Breakdown]
    public let updatedAt: Date?
    public let unpricedModelCount: Int
    public var pricingNotice: String? {
        unpricedModelCount > 0
            ? "Cost estimates are incomplete for \(unpricedModelCount) unpriced model\(unpricedModelCount == 1 ? "" : "s"). Token totals include this usage."
            : nil
    }
    public var activeDays: Int { days.filter { $0.tokens > 0 || $0.cost > 0 }.count }
    public var chartUsesTokens: Bool { total.cost == 0 && total.tokens > 0 }

    public init(
        document: SurfaceUsageDocument, tile: SurfaceTile, now: Date = .now,
        calendar: Calendar = .current
    ) {
        let end = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: 1 - tile.days, to: end) ?? end
        let weekStart = calendar.date(byAdding: .day, value: -6, to: end) ?? end
        let selected =
            tile.sourceIDs ?? document.defaultSources.flatMap { $0.isEmpty ? nil : Set($0) }
        var byDay: [String: Total] = [:]
        var byProvider: [String: Total] = [:]
        var byModel: [String: Total] = [:]
        var today = Total(); var week = Total(); var total = Total()
        var unpriced: Set<String> = []
        for day in document.daily {
            let parts = day.period.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 3,
                let date = calendar.date(
                    from: DateComponents(year: parts[0], month: parts[1], day: parts[2])),
                date <= end,
                date >= min(start, weekStart)
            else { continue }
            var amount = Total()
            for (source, rows) in day.bySource ?? [:] where selected?.contains(source) ?? true {
                for row in rows {
                    let cost = Self.valid(row.cost); let tokens = row.tokens
                    amount.add(cost: cost, tokens: tokens)
                    if date >= start {
                        if row.costMissing == true || Self.valid(row.unpricedTokens) > 0 {
                            unpriced.insert(row.modelName ?? "Unknown model")
                        }
                        byProvider[source, default: Total()].add(cost: cost, tokens: tokens)
                        byModel[row.modelName ?? "Unknown model", default: Total()].add(
                            cost: cost, tokens: tokens)
                    }
                }
            }
            if date == end { today.add(cost: amount.cost, tokens: amount.tokens) }
            if date >= weekStart { week.add(cost: amount.cost, tokens: amount.tokens) }
            if date >= start {
                byDay[day.period, default: Total()].add(cost: amount.cost, tokens: amount.tokens)
                total.add(cost: amount.cost, tokens: amount.tokens)
            }
        }
        self.today = today; self.week = week; self.total = total
        unpricedModelCount = unpriced.count
        days = (0..<max(1, tile.days)).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: start) else {
                return nil
            }
            let period = Self.period(date, calendar: calendar)
            let value = byDay[period] ?? Total()
            return DayPoint(id: period, date: date, cost: value.cost, tokens: value.tokens)
        }
        providers = Self.ranked(byProvider) { document.sourceMeta?[$0]?.label ?? $0 }
        models = Self.ranked(byModel) { $0 }
        updatedAt = document.generatedAt.flatMap { ISO8601DateFormatter().date(from: $0) }
    }

    static func valid(_ value: Double?) -> Double {
        guard let value, value.isFinite, value > 0 else { return 0 }
        return value
    }
    private static func ranked(
        _ values: [String: Total], title: (String) -> String
    ) -> [Breakdown] {
        values.filter { $0.value.cost > 0 || $0.value.tokens > 0 }.map {
            Breakdown(id: $0.key, title: title($0.key), total: $0.value)
        }.sorted {
            if $0.total.cost != $1.total.cost { return $0.total.cost > $1.total.cost }
            if $0.total.tokens != $1.total.tokens { return $0.total.tokens > $1.total.tokens }
            return $0.id < $1.id
        }
    }
    private static func period(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
