import Foundation

public struct ActivityCalendarDay: Identifiable, Equatable, Sendable {
    public let id: String
    public let date: Date?
    public let value: Double
    public let level: Int

    public init(id: String, date: Date?, value: Double = 0, level: Int = 0) {
        self.id = id
        self.date = date
        self.value = value.isFinite ? min(9e15, max(0, value)) : 0
        self.level = min(4, max(-1, level))
    }
}

public struct ActivityCalendarWeek: Identifiable, Equatable, Sendable {
    public let id: Int
    public let monthLabel: String
    public let cells: [ActivityCalendarDay]

    public init(id: Int, monthLabel: String, cells: [ActivityCalendarDay]) {
        self.id = id
        self.monthLabel = monthLabel
        self.cells = cells
    }
}

public enum ActivityCalendar {
    public static func cuts(_ values: [Double]) -> [Double] {
        let positive = values.filter { $0 > 0 && $0.isFinite }.sorted()
        guard !positive.isEmpty else { return [] }
        return [0.25, 0.5, 0.75].map { positive[Int(Double(positive.count - 1) * $0)] }
    }

    public static func level(_ value: Double, cuts: [Double]) -> Int {
        value > 0 && !cuts.isEmpty ? 1 + cuts.filter { value > $0 }.count : 0
    }

    public static func weeks(
        days: [ActivityCalendarDay], calendar: Calendar = .current,
        cuts suppliedCuts: [Double]? = nil
    ) -> [ActivityCalendarWeek] {
        let days = days.filter { $0.date?.timeIntervalSince1970.isFinite == true }
            .sorted { $0.date! < $1.date! }
        guard let firstDate = days.first?.date, let lastDate = days.last?.date else { return [] }
        let last = calendar.startOfDay(for: lastDate)
        let lower = calendar.date(byAdding: .day, value: -36_524, to: last) ?? last
        let first = max(calendar.startOfDay(for: firstDate), lower)
        let byDate = Dictionary(
            days.map { (calendar.startOfDay(for: $0.date!), $0) },
            uniquingKeysWith: { _, latest in latest })
        let cuts = suppliedCuts ?? Self.cuts(days.map(\.value))
        let padding = (calendar.component(.weekday, from: first) - calendar.firstWeekday + 7) % 7
        var cells = (0..<padding).map {
            ActivityCalendarDay(id: "padding-start-\($0)", date: nil, level: -1)
        }
        var date = first
        while date <= last {
            let day = byDate[date]
            let value = day?.value ?? 0
            cells.append(
                ActivityCalendarDay(
                    id: day?.id ?? "gap-\(date.timeIntervalSinceReferenceDate)", date: date,
                    value: value, level: level(value, cuts: cuts)))
            guard let next = calendar.date(byAdding: .day, value: 1, to: date), next > date else {
                break
            }
            date = calendar.startOfDay(for: next)
        }
        let trailing = (7 - cells.count % 7) % 7
        cells += (0..<trailing).map {
            ActivityCalendarDay(id: "padding-end-\($0)", date: nil, level: -1)
        }
        var previousMonth: Int?
        return stride(from: 0, to: cells.count, by: 7).map { start in
            let week = Array(cells[start..<start + 7])
            let month = week.compactMap(\.date).first.map { calendar.component(.month, from: $0) }
            let label =
                month.flatMap { $0 == previousMonth ? nil : calendar.shortMonthSymbols[$0 - 1] }
                ?? ""
            previousMonth = month ?? previousMonth
            return ActivityCalendarWeek(id: start / 7, monthLabel: label, cells: week)
        }
    }
}
