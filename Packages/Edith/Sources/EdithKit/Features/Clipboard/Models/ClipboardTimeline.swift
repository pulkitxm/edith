import Foundation

public struct ClipboardSection: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let entries: [ClipboardEntry]

    public init(id: String, title: String, entries: [ClipboardEntry]) {
        self.id = id
        self.title = title
        self.entries = entries
    }
}

public enum ClipboardTimeline {
    public static let pinnedTitle = "Pinned"

    public static func sections(
        _ arranged: [ClipboardEntry], now: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent
    ) -> [ClipboardSection] {
        let today = calendar.startOfDay(for: now)
        var sections: [ClipboardSection] = []
        var seen: [String: Int] = [:]
        var key = ""
        var title = ""
        var members: [ClipboardEntry] = []

        func flush() {
            guard !members.isEmpty else { return }
            let occurrence = seen[key, default: 0]
            seen[key] = occurrence + 1
            let id = occurrence == 0 ? key : "\(key)#\(occurrence)"
            sections.append(ClipboardSection(id: id, title: title, entries: members))
            members = []
        }

        for entry in arranged {
            let entryKey: String
            let entryTitle: String
            if entry.pinned {
                entryKey = "pinned"
                entryTitle = pinnedTitle
            } else {
                let day = min(calendar.startOfDay(for: entry.lastCopiedAt), today)
                entryKey = "day-\(Int(day.timeIntervalSince1970))"
                entryTitle = dayTitle(day, today: today, calendar: calendar)
            }
            if entryKey != key {
                flush()
                key = entryKey
                title = entryTitle
            }
            members.append(entry)
        }
        flush()
        return sections
    }

    public static func dayTitle(_ day: Date, today: Date, calendar: Calendar) -> String {
        let distance = calendar.dateComponents([.day], from: day, to: today).day ?? 0
        let style = Date.FormatStyle(
            locale: calendar.locale ?? .autoupdatingCurrent, calendar: calendar,
            timeZone: calendar.timeZone)
        switch distance {
        case ..<1: return "Today"
        case 1: return "Yesterday"
        case 2..<7: return day.formatted(style.weekday(.wide))
        default:
            let sameYear =
                calendar.component(.year, from: day) == calendar.component(.year, from: today)
            return sameYear
                ? day.formatted(style.month(.wide).day())
                : day.formatted(style.month(.wide).day().year())
        }
    }

    public static func timeLabel(_ date: Date, calendar: Calendar = .autoupdatingCurrent)
        -> String
    {
        date.formatted(
            Date.FormatStyle(
                date: .omitted, time: .shortened,
                locale: calendar.locale ?? .autoupdatingCurrent, calendar: calendar,
                timeZone: calendar.timeZone))
    }

    public static func dayAndTimeLabel(
        _ date: Date, calendar: Calendar = .autoupdatingCurrent
    ) -> String {
        let style = Date.FormatStyle(
            locale: calendar.locale ?? .autoupdatingCurrent, calendar: calendar,
            timeZone: calendar.timeZone)
        return date.formatted(style.month(.abbreviated).day().hour().minute())
    }

    public static func subtitle(
        for entry: ClipboardEntry, now: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent
    ) -> String {
        let showsDay = entry.pinned && !calendar.isDate(entry.lastCopiedAt, inSameDayAs: now)
        let time =
            showsDay
            ? dayAndTimeLabel(entry.lastCopiedAt, calendar: calendar)
            : timeLabel(entry.lastCopiedAt, calendar: calendar)
        guard let source = entry.sourceApp?.trimmingCharacters(in: .whitespacesAndNewlines),
            !source.isEmpty
        else { return time }
        return "\(source) · \(time)"
    }
}
