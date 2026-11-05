import Foundation

extension Calendar {
    fileprivate var dateFilterGregorian: Calendar {
        guard identifier != .gregorian else { return self }
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = timeZone
        gregorian.locale = locale
        gregorian.firstWeekday = firstWeekday
        gregorian.minimumDaysInFirstWeek = minimumDaysInFirstWeek
        return gregorian
    }
}

public struct DateFilterDay: Comparable, Hashable, Sendable {
    public let year: Int
    public let month: Int
    public let day: Int

    public init?(year: Int, month: Int, day: Int) {
        guard (1...9999).contains(year), (1...12).contains(month),
            (1...Self.daysInMonth(year: year, month: month)).contains(day)
        else { return nil }
        self.year = year
        self.month = month
        self.day = day
    }

    public init?(_ string: String) {
        let parts = string.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
            let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2])
        else { return nil }
        self.init(year: year, month: month, day: day)
    }

    public init(date: Date, calendar: Calendar) {
        let parts = calendar.dateFilterGregorian.dateComponents(
            [.year, .month, .day], from: date)
        self.init(serial: Self.serial(parts.year ?? 1970, parts.month ?? 1, parts.day ?? 1))
    }

    fileprivate init(firstOf month: Int, year: Int) {
        self.init(serial: Self.serial(year, month, 1))
    }

    init(serial: Int) {
        let shifted = serial + 719_468
        let era = (shifted >= 0 ? shifted : shifted - 146_096) / 146_097
        let dayOfEra = shifted - era * 146_097
        let yearOfEra =
            (dayOfEra - dayOfEra / 1_460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let monthIndex = (5 * dayOfYear + 2) / 153
        day = dayOfYear - (153 * monthIndex + 2) / 5 + 1
        month = monthIndex < 10 ? monthIndex + 3 : monthIndex - 9
        year = yearOfEra + era * 400 + (month <= 2 ? 1 : 0)
    }

    private static func serial(_ year: Int, _ month: Int, _ day: Int) -> Int {
        let shiftedYear = month <= 2 ? year - 1 : year
        let era = (shiftedYear >= 0 ? shiftedYear : shiftedYear - 399) / 400
        let yearOfEra = shiftedYear - era * 400
        let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    static func daysInMonth(year: Int, month: Int) -> Int {
        switch month {
        case 2: year % 4 == 0 && (year % 100 != 0 || year % 400 == 0) ? 29 : 28
        case 4, 6, 9, 11: 30
        default: 31
        }
    }

    var serial: Int { Self.serial(year, month, day) }

    public var string: String { String(format: "%04d-%02d-%02d", year, month, day) }

    public var weekday: Int { ((serial + 4) % 7 + 7) % 7 + 1 }

    public func date(calendar: Calendar) -> Date {
        let gregorian = calendar.dateFilterGregorian
        let noon = gregorian.date(
            from: DateComponents(year: year, month: month, day: day, hour: 12))
        return gregorian.startOfDay(for: noon ?? Date(timeIntervalSince1970: 0))
    }

    public func advanced(by days: Int) -> DateFilterDay {
        DateFilterDay(serial: serial + days)
    }

    public func distance(to other: DateFilterDay) -> Int {
        other.serial - serial
    }

    public func title(calendar: Calendar) -> String {
        "\(shortTitle(calendar: calendar)) \(year)"
    }

    public func accessibilityTitle(calendar: Calendar) -> String {
        let gregorian = calendar.dateFilterGregorian
        let weekdayName = gregorian.weekdaySymbols[weekday - 1]
        return "\(weekdayName), \(day) \(gregorian.monthSymbols[month - 1]) \(year)"
    }

    func shortTitle(calendar: Calendar) -> String {
        "\(day) \(calendar.dateFilterGregorian.shortMonthSymbols[month - 1])"
    }

    func weekStart(firstWeekday: Int) -> DateFilterDay {
        advanced(by: -((weekday - firstWeekday + 7) % 7))
    }

    public static func < (lhs: DateFilterDay, rhs: DateFilterDay) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }
}

public struct DateFilterMonth: Comparable, Hashable, Identifiable, Sendable {
    public let year: Int
    public let month: Int

    public init?(year: Int, month: Int) {
        guard (1...9999).contains(year), (1...12).contains(month) else { return nil }
        self.year = year
        self.month = month
    }

    public init?(_ string: String) {
        let parts = string.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].count == 4, parts[1].count == 2,
            let year = Int(parts[0]), let month = Int(parts[1])
        else { return nil }
        self.init(year: year, month: month)
    }

    public init(containing day: DateFilterDay) {
        year = day.year
        month = day.month
    }

    private init(index: Int) {
        year = index / 12
        month = index % 12 + 1
    }

    public var id: String { string }

    public var string: String { String(format: "%04d-%02d", year, month) }

    public var firstDay: DateFilterDay {
        DateFilterDay(firstOf: month, year: year)
    }

    public var lastDay: DateFilterDay {
        firstDay.advanced(by: DateFilterDay.daysInMonth(year: year, month: month) - 1)
    }

    public var range: DateFilterRange { DateFilterRange(firstDay, lastDay) }

    public func advanced(by months: Int) -> DateFilterMonth {
        DateFilterMonth(index: year * 12 + month - 1 + months)
    }

    public func title(calendar: Calendar) -> String {
        "\(calendar.dateFilterGregorian.standaloneMonthSymbols[month - 1]) \(year)"
    }

    public static func < (lhs: DateFilterMonth, rhs: DateFilterMonth) -> Bool {
        (lhs.year, lhs.month) < (rhs.year, rhs.month)
    }
}

public struct DateFilterRange: Hashable, Sendable {
    public let first: DateFilterDay
    public let last: DateFilterDay

    public init(_ start: DateFilterDay, _ end: DateFilterDay) {
        first = min(start, end)
        last = max(start, end)
    }

    fileprivate init(year: Int) {
        first = DateFilterDay(firstOf: 1, year: year)
        last = DateFilterDay(firstOf: 1, year: year + 1).advanced(by: -1)
    }

    public var days: Int { first.distance(to: last) + 1 }

    public var firstString: String { first.string }

    public var lastString: String { last.string }

    public func contains(_ day: DateFilterDay) -> Bool {
        first <= day && day <= last
    }

    public func interval(calendar: Calendar) -> DateInterval {
        DateInterval(
            start: first.date(calendar: calendar),
            end: last.advanced(by: 1).date(calendar: calendar))
    }

    public func title(calendar: Calendar) -> String {
        if let wholeMonth { return wholeMonth.title(calendar: calendar) }
        if let wholeYear { return String(wholeYear) }
        if days == 1 {
            let weekday = calendar.dateFilterGregorian.shortWeekdaySymbols[first.weekday - 1]
            return "\(weekday) \(first.title(calendar: calendar))"
        }
        let start = first.shortTitle(calendar: calendar)
        let end = last.shortTitle(calendar: calendar)
        return first.year == last.year
            ? "\(start) to \(end) \(last.year)"
            : "\(first.title(calendar: calendar)) to \(last.title(calendar: calendar))"
    }

    var wholeMonth: DateFilterMonth? {
        let month = DateFilterMonth(containing: first)
        return month.range == self ? month : nil
    }

    var wholeYear: Int? {
        first.month == 1 && first.day == 1 && last.month == 12 && last.day == 31
            && first.year == last.year ? first.year : nil
    }
}

public enum DateFilterPreset: String, CaseIterable, Identifiable, Sendable {
    case today
    case yesterday
    case thisWeek
    case lastWeek
    case last7
    case last14
    case thisMonth
    case lastMonth
    case last30
    case last90
    case thisYear
    case lastYear
    case last12Months
    case allTime = "all"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .today: "Today"
        case .yesterday: "Yesterday"
        case .thisWeek: "This week"
        case .lastWeek: "Last week"
        case .last7: "Last 7 days"
        case .last14: "Last 14 days"
        case .thisMonth: "This month"
        case .lastMonth: "Last month"
        case .last30: "Last 30 days"
        case .last90: "Last 90 days"
        case .thisYear: "This year"
        case .lastYear: "Last year"
        case .last12Months: "Last 12 months"
        case .allTime: "All time"
        }
    }

    public var chipTitle: String {
        switch self {
        case .last7: "7 days"
        case .last14: "14 days"
        case .last30: "30 days"
        case .last90: "90 days"
        default: title
        }
    }

    public static let quick: [DateFilterPreset] = [.today, .last7, .last30, .last90, .allTime]

    public static let groups: [[DateFilterPreset]] = [
        [.today, .yesterday],
        [.thisWeek, .lastWeek, .last7, .last14],
        [.thisMonth, .lastMonth, .last30, .last90],
        [.thisYear, .lastYear, .last12Months],
        [.allTime],
    ]

    func range(today: DateFilterDay, firstWeekday: Int) -> DateFilterRange? {
        let week = today.weekStart(firstWeekday: firstWeekday)
        let month = DateFilterMonth(containing: today)
        func trailing(_ days: Int) -> DateFilterRange {
            DateFilterRange(today.advanced(by: 1 - days), today)
        }
        switch self {
        case .today: return trailing(1)
        case .yesterday:
            return DateFilterRange(today.advanced(by: -1), today.advanced(by: -1))
        case .thisWeek: return DateFilterRange(week, today)
        case .lastWeek: return DateFilterRange(week.advanced(by: -7), week.advanced(by: -1))
        case .last7: return trailing(7)
        case .last14: return trailing(14)
        case .thisMonth: return DateFilterRange(month.firstDay, today)
        case .lastMonth: return month.advanced(by: -1).range
        case .last30: return trailing(30)
        case .last90: return trailing(90)
        case .thisYear: return DateFilterRange(DateFilterDay(firstOf: 1, year: today.year), today)
        case .lastYear: return DateFilterRange(year: today.year - 1)
        case .last12Months:
            let anchor = DateFilterMonth(year: today.year - 1, month: today.month)
            let lastDay = anchor?.lastDay ?? today
            let sameDay = anchor?.firstDay.advanced(by: min(today.day, lastDay.day) - 1) ?? today
            return DateFilterRange(sameDay.advanced(by: 1), today)
        case .allTime: return nil
        }
    }
}

public enum DateFilterSelection: Hashable, RawRepresentable, Sendable {
    case preset(DateFilterPreset)
    case month(DateFilterMonth)
    case custom(DateFilterRange)

    public init?(rawValue: String) {
        if let preset = DateFilterPreset(rawValue: rawValue) {
            self = .preset(preset)
        } else if rawValue.hasPrefix("month:") {
            guard let month = DateFilterMonth(String(rawValue.dropFirst(6))) else { return nil }
            self = .month(month)
        } else if rawValue.hasPrefix("custom:") {
            let parts = rawValue.dropFirst(7).components(separatedBy: "~")
            guard parts.count == 2, let first = DateFilterDay(parts[0]),
                let last = DateFilterDay(parts[1])
            else { return nil }
            self = .custom(DateFilterRange(first, last))
        } else {
            return nil
        }
    }

    public var rawValue: String {
        switch self {
        case .preset(let preset): preset.rawValue
        case .month(let month): "month:\(month.string)"
        case .custom(let range): "custom:\(range.firstString)~\(range.lastString)"
        }
    }

    public func range(now: Date = Date(), calendar: Calendar = .current) -> DateFilterRange? {
        let today = DateFilterDay(date: now, calendar: calendar)
        switch self {
        case .preset(let preset):
            return preset.range(today: today, firstWeekday: calendar.firstWeekday)
        case .month(let month):
            return month.range.contains(today)
                ? DateFilterRange(month.firstDay, today) : month.range
        case .custom(let range):
            return range
        }
    }

    public func interval(now: Date = Date(), calendar: Calendar = .current) -> DateInterval? {
        range(now: now, calendar: calendar)?.interval(calendar: calendar)
    }

    public func title(calendar: Calendar = .current) -> String {
        switch self {
        case .preset(let preset): preset.title
        case .month(let month): month.title(calendar: calendar)
        case .custom(let range): range.title(calendar: calendar)
        }
    }

    public func periodLabel(now: Date = Date(), calendar: Calendar = .current) -> String {
        guard let range = range(now: now, calendar: calendar) else {
            return DateFilterPreset.allTime.title
        }
        let today = DateFilterDay(date: now, calendar: calendar)
        switch self {
        case .preset(.thisMonth):
            return DateFilterMonth(containing: today).title(calendar: calendar)
        case .month(let month):
            return month.title(calendar: calendar)
        case .preset(.thisYear):
            return String(today.year)
        default:
            if range.days == 1, range.first == today { return DateFilterPreset.today.title }
            if range.days == 1, range.first == today.advanced(by: -1) {
                return DateFilterPreset.yesterday.title
            }
            return range.title(calendar: calendar)
        }
    }

    public func canonical(now: Date = Date(), calendar: Calendar = .current) -> Self {
        let named = canonical(among: DateFilterPreset.allCases, now: now, calendar: calendar)
        if case .custom(let range) = named, let month = range.wholeMonth { return .month(month) }
        return named
    }

    private func canonical(
        among presets: [DateFilterPreset], now: Date, calendar: Calendar
    ) -> Self {
        if case .preset = self { return self }
        guard let range = range(now: now, calendar: calendar) else { return self }
        let today = DateFilterDay(date: now, calendar: calendar)
        let match = presets.first {
            $0.range(today: today, firstWeekday: calendar.firstWeekday) == range
        }
        return match.map { .preset($0) } ?? self
    }

    public var isSteppable: Bool { self != .preset(.allTime) }

    public func canStepForward(now: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard let range = range(now: now, calendar: calendar) else { return false }
        return range.last < DateFilterDay(date: now, calendar: calendar)
    }

    public func canStepBackward(
        earliest: DateFilterDay? = nil, now: Date = Date(), calendar: Calendar = .current
    ) -> Bool {
        guard let range = range(now: now, calendar: calendar) else { return false }
        guard let earliest else { return true }
        return range.first > earliest
    }

    public func stepped(
        by steps: Int, now: Date = Date(), calendar: Calendar = .current
    ) -> Self {
        guard let range = range(now: now, calendar: calendar) else { return self }
        let today = DateFilterDay(date: now, calendar: calendar)
        switch unit(range) {
        case .month(let month):
            let target = min(month.advanced(by: steps), DateFilterMonth(containing: today))
            return Self.month(target)
                .canonical(among: [.thisMonth, .lastMonth], now: now, calendar: calendar)
        case .year(let year):
            let target = year + steps
            guard target < today.year else { return .preset(.thisYear) }
            return Self.custom(DateFilterRange(year: target))
                .canonical(among: [.lastYear], now: now, calendar: calendar)
        case .week:
            let currentWeek = today.weekStart(firstWeekday: calendar.firstWeekday)
            let start = range.first.advanced(by: steps * 7)
            guard start < currentWeek else { return .preset(.thisWeek) }
            return Self.custom(DateFilterRange(start, start.advanced(by: 6)))
                .canonical(among: [.lastWeek], now: now, calendar: calendar)
        case .days(let length):
            let last = min(range.last.advanced(by: steps * length), today)
            return Self.custom(DateFilterRange(last.advanced(by: 1 - length), last))
                .canonical(among: DateFilterPreset.allCases, now: now, calendar: calendar)
        }
    }

    private enum StepUnit {
        case days(Int)
        case week
        case month(DateFilterMonth)
        case year(Int)
    }

    private func unit(_ range: DateFilterRange) -> StepUnit {
        switch self {
        case .preset(.thisWeek), .preset(.lastWeek): return .week
        case .preset(.thisMonth), .preset(.lastMonth), .month:
            return .month(DateFilterMonth(containing: range.first))
        case .preset(.thisYear), .preset(.lastYear): return .year(range.first.year)
        case .custom:
            if let month = range.wholeMonth { return .month(month) }
            if let year = range.wholeYear { return .year(year) }
            return .days(range.days)
        default: return .days(range.days)
        }
    }
}

public struct DateFilterDraft: Equatable, Sendable {
    public enum Endpoint: Sendable {
        case start
        case end
    }

    public private(set) var start: DateFilterDay?
    public private(set) var end: DateFilterDay?
    public private(set) var cursor: DateFilterDay
    public private(set) var visibleMonth: DateFilterMonth
    public let earliest: DateFilterDay?
    public let latest: DateFilterDay
    public var editing = Endpoint.start

    public init(range: DateFilterRange?, earliest: DateFilterDay?, latest: DateFilterDay) {
        let lower = earliest.map { min($0, latest) }
        self.earliest = lower
        self.latest = latest
        func clamped(_ day: DateFilterDay) -> DateFilterDay {
            let capped = min(day, latest)
            return lower.map { max($0, capped) } ?? capped
        }
        start = range.map { clamped($0.first) }
        end = range.map { clamped($0.last) }
        cursor = range.map { clamped($0.last) } ?? latest
        visibleMonth = DateFilterMonth(containing: cursor)
    }

    public var range: DateFilterRange? {
        guard let start, let end else { return nil }
        return DateFilterRange(start, end)
    }

    public var canApply: Bool { range != nil }

    public func allows(_ day: DateFilterDay) -> Bool {
        day <= latest && (earliest.map { $0 <= day } ?? true)
    }

    public mutating func select(_ day: DateFilterDay) {
        guard allows(day) else { return }
        cursor = day
        visibleMonth = DateFilterMonth(containing: day)
        switch editing {
        case .start:
            if let end, end < day { self.end = nil }
            start = day
            editing = .end
        case .end:
            if let start, day < start {
                end = start
                self.start = day
            } else {
                if start == nil { start = day }
                end = day
            }
            editing = .start
        }
    }

    public mutating func edit(_ endpoint: Endpoint) {
        editing = endpoint
        guard let day = endpoint == .start ? start : end else { return }
        cursor = day
        visibleMonth = DateFilterMonth(containing: day)
    }

    public mutating func moveCursor(byDays days: Int) {
        move(to: cursor.advanced(by: days))
    }

    public mutating func moveCursor(byMonths months: Int) {
        let month = DateFilterMonth(containing: cursor).advanced(by: months)
        move(to: month.firstDay.advanced(by: min(cursor.day, month.lastDay.day) - 1))
    }

    public mutating func selectCursor() {
        select(cursor)
    }

    private mutating func move(to day: DateFilterDay) {
        let capped = min(day, latest)
        cursor = earliest.map { max($0, capped) } ?? capped
        visibleMonth = DateFilterMonth(containing: cursor)
    }

    public var canShowPreviousMonth: Bool {
        earliest.map { DateFilterMonth(containing: $0) < visibleMonth } ?? true
    }

    public var canShowNextMonth: Bool { visibleMonth < DateFilterMonth(containing: latest) }

    public mutating func showMonth(offset: Int) {
        let month = visibleMonth.advanced(by: offset)
        move(to: month.firstDay.advanced(by: min(cursor.day, month.lastDay.day) - 1))
        visibleMonth = month
    }

    public func gridDays(firstWeekday: Int) -> [DateFilterDay] {
        let first = visibleMonth.firstDay.weekStart(firstWeekday: firstWeekday)
        return (0..<42).map { first.advanced(by: $0) }
    }
}
