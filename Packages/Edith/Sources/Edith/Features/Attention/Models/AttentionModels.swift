import Foundation

enum AttentionSection: String, CaseIterable, Identifiable {
    case overview
    case timeline
    case insights
    case focus
    case library
    case music
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .timeline: "Timeline"
        case .insights: "Insights"
        case .focus: "Focus"
        case .library: "Library"
        case .music: "Music"
        case .settings: "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .overview: "rectangle.grid.2x2"
        case .timeline: "timeline.selection"
        case .insights: "sparkles"
        case .focus: "scope"
        case .library: "square.grid.3x3"
        case .music: "music.note.list"
        case .settings: "slider.horizontal.3"
        }
    }
}

enum AttentionRange: String, CaseIterable, Identifiable {
    case day
    case week
    case month

    var id: String { rawValue }

    var title: String {
        switch self {
        case .day: "Day"
        case .week: "Week"
        case .month: "Month"
        }
    }

    var dayCount: Int {
        switch self {
        case .day: 1
        case .week: 7
        case .month: 31
        }
    }
}

enum AttentionPresence: String, CaseIterable, Identifiable {
    case active
    case passive
    case away
    case uncertain

    var id: String { rawValue }

    var title: String {
        switch self {
        case .active: "Interactive"
        case .passive: "Passive likely"
        case .away: "Away"
        case .uncertain: "Uncertain"
        }
    }

    var symbol: String {
        switch self {
        case .active: "cursorarrow.motionlines"
        case .passive: "play.rectangle"
        case .away: "person.crop.circle.badge.clock"
        case .uncertain: "questionmark.circle"
        }
    }
}

enum AttentionSurface: String, CaseIterable, Identifiable {
    case native
    case web

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum AttentionCategoryKind: String, CaseIterable, Identifiable {
    case productive
    case neutral
    case distracting
    case entertainment

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

struct AttentionCategory: Identifiable, Hashable {
    let id: String
    var name: String
    var parent: String?
    var kind: AttentionCategoryKind
    var symbol: String

    var path: String {
        guard let parent else { return name }
        return "\(parent) / \(name)"
    }
}

struct AttentionSegment: Identifiable, Hashable {
    let id: UUID
    var start: Date
    var end: Date
    var application: String
    var service: String
    var title: String
    var categoryID: String
    var presence: AttentionPresence
    var surface: AttentionSurface
    var browser: String?
    var profile: String?
    var confidence: Double
    var focusSession: String?
    var automation: String?

    var duration: TimeInterval { max(0, end.timeIntervalSince(start)) }
}

struct AttentionMediaSession: Identifiable, Hashable {
    let id: UUID
    var start: Date
    var end: Date
    var service: String
    var track: String
    var artist: String
    var album: String
    var playedSeconds: TimeInterval
    var durationSeconds: TimeInterval
    var source: String
    var profile: String?
    var foreground: Bool
    var completed: Bool

    var completion: Double {
        guard durationSeconds > 0 else { return 0 }
        return min(1, playedSeconds / durationSeconds)
    }
}

struct AttentionFocusSession: Identifiable, Hashable {
    let id: UUID
    var start: Date
    var end: Date
    var name: String
    var goal: String
    var intendedSeconds: TimeInterval
    var offIntentSeconds: TimeInterval
    var interruptions: Int
    var automationSeconds: TimeInterval

    var duration: TimeInterval { max(0, end.timeIntervalSince(start)) }
    var focusRatio: Double {
        let present = intendedSeconds + offIntentSeconds
        return present > 0 ? intendedSeconds / present : 0
    }
}

struct AttentionIdentity: Identifiable, Hashable {
    let id: String
    var name: String
    var symbol: String
    var categoryID: String
    var nativeApplications: [String]
    var domains: [String]
    var totalSeconds: TimeInterval
    var lastUsed: Date
    var ruleSource: String
}

struct AttentionBrowserProfile: Identifiable, Hashable {
    let id: UUID
    var browser: String
    var profile: String
    var symbol: String
    var connected: Bool
    var deepMode: Bool
    var historyImported: Bool
    var lastSeen: Date
    var eventCount: Int
}

struct AttentionDailySummary: Identifiable, Hashable {
    var id: Date { date }
    var date: Date
    var activeSeconds: TimeInterval
    var passiveSeconds: TimeInterval
    var awaySeconds: TimeInterval
    var uncertainSeconds: TimeInterval
    var focusSeconds: TimeInterval
    var distractingSeconds: TimeInterval
    var entertainmentSeconds: TimeInterval
    var musicSeconds: TimeInterval
    var automationSeconds: TimeInterval
    var switches: Int
}

struct AttentionInsight: Identifiable, Hashable {
    let id: String
    var symbol: String
    var title: String
    var detail: String
    var value: String
    var category: String
    var confidence: Double
}

struct AttentionFocusTemplate: Identifiable, Hashable {
    let id: String
    var name: String
    var symbol: String
    var durationMinutes: Int?
    var allowedCategoryIDs: [String]
    var intervention: String
    var graceSeconds: Int
}

struct AttentionSetupStep: Identifiable, Hashable {
    let id: String
    var title: String
    var detail: String
    var symbol: String
    var completed: Bool
}

struct AttentionMetric: Identifiable, Hashable {
    let id: String
    var title: String
    var value: String
    var detail: String
    var symbol: String
}

enum AttentionTime {
    static func duration(_ seconds: TimeInterval, compact: Bool = false) -> String {
        let value = max(0, Int(seconds.rounded()))
        let hours = value / 3600
        let minutes = value % 3600 / 60
        if compact {
            if hours > 0 { return "\(hours)h \(minutes)m" }
            return "\(minutes)m"
        }
        if hours > 0 { return "\(hours) hr \(minutes) min" }
        return "\(minutes) min"
    }

    static func clock(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    static func day(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }
}
