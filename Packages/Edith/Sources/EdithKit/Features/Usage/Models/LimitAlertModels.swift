import Foundation

public enum LimitAlertKind: String, CaseIterable, Codable, Sendable {
    case capped
    case almostCapped = "almost_capped"
    case onPace = "on_pace"
    case headroom
    case outlook
    case back
    case login

    public var isCritical: Bool {
        switch self {
        case .capped, .almostCapped, .back, .login: true
        case .onPace, .headroom, .outlook: false
        }
    }
}

public struct LimitAlertTarget: Hashable, Codable, Sendable {
    public let provider: LimitProvider
    public let slot: LimitWindowSlot

    public init(_ provider: LimitProvider, _ slot: LimitWindowSlot) {
        self.provider = provider
        self.slot = slot
    }

    public static let all: [LimitAlertTarget] = [LimitProvider.claude, .codex].flatMap { provider in
        MenuBarLimits.slots(for: provider).map { LimitAlertTarget(provider, $0) }
    }

    public var id: String { "\(provider.rawValue).\(slot.rawValue)" }
    public var isWeekly: Bool { slot != .session }
    public var duration: TimeInterval { slot.kind.duration }
    var sameWindowTolerance: TimeInterval { isWeekly ? 12 * 3600 : 3600 }

    public var label: String {
        switch slot {
        case .session: "\(provider.label) 5h"
        case .week: "\(provider.label) weekly"
        case .fable: "\(provider.label) Fable weekly"
        }
    }
}

public struct LimitAlertSample: Equatable, Sendable {
    public let date: Date
    public let percent: Double
    public let resetsAt: Date?

    public init(date: Date, percent: Double, resetsAt: Date?) {
        self.date = date
        self.percent = percent
        self.resetsAt = resetsAt
    }
}

public enum LimitLoginProblem: String, Codable, Sendable {
    case expired, missing, denied

    public init?(error: String) {
        let text = error.lowercased()
        if text.contains("cannot read usage") || text.contains("permission")
            || text.contains("403")
        {
            self = .denied
        } else if text.contains("token not found") {
            self = .missing
        } else if text.contains("expired") || text.contains("login") || text.contains("logged in")
            || text.contains("unauthorized") || text.contains("401")
        {
            self = .expired
        } else {
            return nil
        }
    }
}

public struct LimitAlertSettings: Equatable, Sendable {
    public static let defaultAlmostCappedPercent = 90
    public static let almostCappedRange = 50...99

    public var master = false
    public var trackSession = true
    public var trackWeekly = true
    public var onPace = true
    public var almostCapped = true
    public var almostCappedPercent = LimitAlertSettings.defaultAlmostCappedPercent
    public var capped = true
    public var back = true
    public var outlook = false
    public var headroom = false
    public var loginProblems = true
    public var providers = Set(LimitProvider.allCases)

    public init() {}

    public static func fromDefaults(_ d: UserDefaults) -> LimitAlertSettings {
        func flag(_ key: String, _ fallback: Bool) -> Bool {
            d.object(forKey: key) as? Bool ?? fallback
        }
        var s = LimitAlertSettings()
        s.master =
            d.bool(forKey: AppStorageKeys.Notify.master)
            && d.bool(forKey: AppStorageKeys.Tabs.usageEnabled)
        s.trackSession = flag(AppStorageKeys.Notify.trackSession, true)
        s.trackWeekly = flag(AppStorageKeys.Notify.trackWeekly, true)
        s.onPace = flag(AppStorageKeys.Notify.onPace, true)
        s.almostCapped = flag(AppStorageKeys.Notify.almostCapped, true)
        s.almostCappedPercent = min(
            max(
                d.object(forKey: AppStorageKeys.Notify.almostCappedPercent) as? Int
                    ?? defaultAlmostCappedPercent, almostCappedRange.lowerBound),
            almostCappedRange.upperBound)
        s.capped = flag(AppStorageKeys.Notify.capped, true)
        s.back = flag(AppStorageKeys.Notify.back, true)
        s.outlook = flag(AppStorageKeys.Notify.outlook, false)
        s.headroom = flag(AppStorageKeys.Notify.headroom, false)
        s.loginProblems = flag(AppStorageKeys.Notify.loginProblems, true)
        s.providers = Set(
            LimitProvider.allCases.filter { LimitsCollector.providerEnabled($0, defaults: d) })
        return s
    }

    public func tracks(_ target: LimitAlertTarget) -> Bool {
        providers.contains(target.provider) && (target.isWeekly ? trackWeekly : trackSession)
    }

    public func allows(_ kind: LimitAlertKind) -> Bool {
        guard master else { return false }
        switch kind {
        case .capped: return capped
        case .almostCapped: return almostCapped
        case .onPace: return onPace
        case .headroom: return headroom
        case .outlook: return outlook
        case .back: return back
        case .login: return loginProblems
        }
    }

    public func permits(identifier: String) -> Bool {
        let parts = identifier.split(separator: ".").map(String.init)
        guard parts.count == 3 || parts.count == 4, parts[0] == "limits",
            let kind = LimitAlertKind(rawValue: parts[1]),
            let provider = LimitProvider(rawValue: parts[2]),
            allows(kind), providers.contains(provider)
        else { return false }
        guard parts.count == 4 else { return true }
        guard let slot = LimitWindowSlot(rawValue: parts[3]) else { return false }
        return tracks(LimitAlertTarget(provider, slot))
    }
}

public struct LimitAlertClock: Sendable {
    public let now: Date
    public let calendar: Calendar
    public let locale: Locale

    public init(
        now: Date = Date(), calendar: Calendar = .autoupdatingCurrent,
        locale: Locale = .autoupdatingCurrent
    ) {
        self.now = now
        self.calendar = calendar
        self.locale = locale
    }

    public var hour: Int { calendar.component(.hour, from: now) }

    private var style: Date.FormatStyle {
        Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
    }

    public func time(_ date: Date) -> String {
        date.formatted(style.hour().minute())
            .replacingOccurrences(of: "\u{202F}", with: " ")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    public func moment(_ date: Date) -> String {
        switch dayOffset(date) {
        case 0: time(date)
        case 1: "tomorrow " + time(date)
        default: dayName(date) + " " + time(date)
        }
    }

    public func at(_ date: Date) -> String {
        dayOffset(date) == 0 ? "at " + time(date) : moment(date)
    }

    public func dayPart(_ date: Date) -> String {
        let hour = calendar.component(.hour, from: date)
        let part = hour < 12 ? "morning" : hour < 17 ? "afternoon" : hour < 21 ? "evening" : "night"
        switch dayOffset(date) {
        case 0: return part == "night" ? "tonight" : "this " + part
        case 1: return "tomorrow " + part
        default: return dayName(date) + " " + part
        }
    }

    public func day(_ date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    public static func span(_ seconds: TimeInterval) -> String {
        let minutes = max(0, Int((seconds / 60).rounded()))
        let days = minutes / 1440
        let hours = minutes % 1440 / 60
        let rest = minutes % 60
        if days > 0 { return hours > 0 ? "\(days) d \(hours) h" : "\(days) d" }
        if hours > 0 { return rest > 0 ? "\(hours) h \(rest) m" : "\(hours) h" }
        return "\(rest) m"
    }

    public static func days(_ seconds: TimeInterval) -> String {
        let days = seconds / 86_400
        if days >= 1.5 { return "\(Int(days.rounded())) days" }
        if days >= 1 { return "1 day" }
        let hours = max(1, Int((seconds / 3600).rounded()))
        return hours == 1 ? "1 hour" : "\(hours) hours"
    }

    private func dayOffset(_ date: Date) -> Int {
        calendar.dateComponents(
            [.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)
        ).day ?? 0
    }

    private func dayName(_ date: Date) -> String {
        dayOffset(date) < 7
            ? date.formatted(style.weekday(.wide))
            : date.formatted(style.month(.abbreviated).day())
    }
}

public struct LimitAlertLedger: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var resetsAt: Date?
        public var peak = 0.0
        public var sent: [String: Date] = [:]
        public var capAt: Date?
        public var outlookDay: String?
        public var backAt: Date?

        public init(resetsAt: Date? = nil) {
            self.resetsAt = resetsAt
        }
    }

    public var windows: [String: Entry] = [:]
    public var login: [String: String] = [:]

    public init() {}

    public static var outboxURL: URL {
        AppData.supportDir.appendingPathComponent("notifications.json")
    }

    public static func load(from url: URL = outboxURL) -> LimitAlertLedger? {
        struct Outbox: Decodable { let ledger: LimitAlertLedger? }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? AgentPayload.decode(Outbox.self, from: data))?.ledger
    }
}

public struct LimitAlert: Equatable, Sendable {
    public let kind: LimitAlertKind
    public let scope: String
    public let title: String
    public let body: String
    public let reason: String
    public let fireAt: Date?
    public let expiresAt: Date?
    public let facts: [String: String]

    public init(
        kind: LimitAlertKind, scope: String, title: String, body: String, reason: String,
        fireAt: Date? = nil, expiresAt: Date? = nil, facts: [String: String] = [:]
    ) {
        self.kind = kind
        self.scope = scope
        self.title = title
        self.body = body
        self.reason = reason
        self.fireAt = fireAt
        self.expiresAt = expiresAt
        self.facts = facts
    }

    public var identifier: String { "limits.\(kind.rawValue).\(scope)" }
}
