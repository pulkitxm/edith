import Foundation

struct DashboardDateRangeSelection: Equatable {
    var from: Date
    var to: Date
    var choosingEnd = false

    init(from: Date, to: Date, bounds: ClosedRange<Date>, calendar: Calendar = .current) {
        let lower = calendar.startOfDay(for: bounds.lowerBound)
        let upper = calendar.startOfDay(for: bounds.upperBound)
        let start = min(max(calendar.startOfDay(for: from), lower), upper)
        let end = min(max(calendar.startOfDay(for: to), lower), upper)
        self.from = min(start, end)
        self.to = max(start, end)
    }

    mutating func select(
        _ date: Date, bounds: ClosedRange<Date>, calendar: Calendar = .current
    ) {
        let value = calendar.startOfDay(for: date)
        guard bounds.contains(value) else { return }
        if choosingEnd, value >= from {
            to = value
            choosingEnd = false
        } else {
            from = value
            to = value
            choosingEnd = true
        }
    }

    mutating func setTrailing(
        days: Int, bounds: ClosedRange<Date>, calendar: Calendar = .current
    ) {
        let upper = calendar.startOfDay(for: bounds.upperBound)
        from = max(
            calendar.date(byAdding: .day, value: -(max(days, 1) - 1), to: upper) ?? upper,
            bounds.lowerBound)
        to = upper
        choosingEnd = false
    }

    mutating func setMonthToDate(
        bounds: ClosedRange<Date>, calendar: Calendar = .current
    ) {
        let upper = calendar.startOfDay(for: bounds.upperBound)
        from = max(calendar.startOfMonth(containing: upper), bounds.lowerBound)
        to = upper
        choosingEnd = false
    }
}

extension Calendar {
    func startOfMonth(containing date: Date) -> Date {
        self.date(from: dateComponents([.year, .month], from: date)) ?? startOfDay(for: date)
    }
}
