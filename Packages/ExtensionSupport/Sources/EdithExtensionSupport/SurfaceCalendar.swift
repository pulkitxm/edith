import Foundation

public struct SurfaceCalendarDay: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let date: String
    public let level: Int
    public let value: String
    public let action: SurfaceAction?

    public init(_ id: String, date: String, level: Int, value: String, action: SurfaceAction? = nil)
    {
        self.id = id; self.date = date; self.level = level; self.value = value; self.action = action
    }

    public var parsedDate: Date? {
        Self.parse(date)
    }

    public static func parse(_ value: String) -> Date? {
        guard value.utf8.count == 10 else { return nil }
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
            let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
            (1...9999).contains(year), (1...12).contains(month), (1...31).contains(day)
        else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)),
            calendar.component(.year, from: date) == year,
            calendar.component(.month, from: date) == month,
            calendar.component(.day, from: date) == day
        else { return nil }
        return date
    }
}

public struct SurfaceCalendar: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let days: [SurfaceCalendarDay]
    public let sourceID: String?
    public let field: String?

    public init(
        _ id: String, _ title: String, days: [SurfaceCalendarDay], sourceID: String? = nil,
        field: String? = "chart"
    ) {
        self.id = id; self.title = title; self.days = days; self.sourceID = sourceID;
        self.field = field
    }

    func validate() throws {
        guard SurfaceSnapshot.validText(id, maximum: 80),
            SurfaceSnapshot.validText(title, maximum: 256),
            sourceID.map({ SurfaceSnapshot.validText($0, maximum: 2048) }) ?? true,
            field.map({ SurfaceSnapshot.validText($0, maximum: 80) }) ?? true,
            !days.isEmpty, days.count <= 366, Set(days.map(\.id)).count == days.count,
            Set(days.map(\.date)).count == days.count,
            days.map(\.date) == days.map(\.date).sorted(),
            days.allSatisfy({ day in
                SurfaceSnapshot.validText(day.id, maximum: 80) && (0...4).contains(day.level)
                    && SurfaceSnapshot.validText(day.value, maximum: 256, empty: true)
                    && day.parsedDate != nil
                    && (day.action.map { SurfaceSnapshot.validActions([$0]) } ?? true)
            }), let first = days.first?.parsedDate, let last = days.last?.parsedDate,
            last.timeIntervalSince(first) <= 365 * 86_400
        else { throw ExtensionPeerError.invalidRequest }
    }
}
