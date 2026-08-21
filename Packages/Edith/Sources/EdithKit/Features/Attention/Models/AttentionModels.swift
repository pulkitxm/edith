import Foundation

public enum AttentionEventSource: String, Codable, CaseIterable, Sendable {
    case application
    case browser
    case media
    case manual
}

public enum AttentionPresence: String, Codable, CaseIterable, Sendable {
    case active
    case idle
    case locked
}

public enum AttentionPrivacyLevel: String, Codable, CaseIterable, Sendable {
    case applications
    case domains
    case detailed
}

public enum AttentionCategoryKind: String, Codable, CaseIterable, Sendable {
    case focus
    case communication
    case entertainment
    case neutral
    case unclassified
}

public struct AttentionMedia: Codable, Equatable, Sendable {
    public var title: String
    public var artist: String?
    public var album: String?
    public var service: String
    public var kind: String
    public var playing: Bool

    public init(
        title: String, artist: String? = nil, album: String? = nil, service: String,
        kind: String, playing: Bool
    ) {
        self.title = title
        self.artist = artist
        self.album = album
        self.service = service
        self.kind = kind
        self.playing = playing
    }
}

public struct AttentionBrowserHeartbeat: Codable, Equatable, Sendable {
    public var timestamp: Date
    public var duration: TimeInterval
    public var presence: AttentionPresence
    public var appName: String
    public var bundleID: String?
    public var url: String?
    public var domain: String?
    public var title: String?
    public var faviconURL: String?
    public var browserProfile: String?
    public var media: [AttentionMedia]

    public init(
        timestamp: Date, duration: TimeInterval, presence: AttentionPresence,
        appName: String, bundleID: String? = nil, url: String? = nil,
        domain: String? = nil, title: String? = nil, faviconURL: String? = nil,
        browserProfile: String? = nil, media: [AttentionMedia] = []
    ) {
        self.timestamp = timestamp
        self.duration = duration
        self.presence = presence
        self.appName = appName
        self.bundleID = bundleID
        self.url = url
        self.domain = domain
        self.title = title
        self.faviconURL = faviconURL
        self.browserProfile = browserProfile
        self.media = media
    }
}

public struct AttentionEvent: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var startedAt: Date
    public var duration: TimeInterval
    public var source: AttentionEventSource
    public var presence: AttentionPresence
    public var appName: String?
    public var bundleID: String?
    public var windowTitle: String?
    public var url: String?
    public var domain: String?
    public var faviconURL: String?
    public var browserProfile: String?
    public var media: AttentionMedia?

    public init(
        id: String = UUID().uuidString, startedAt: Date, duration: TimeInterval,
        source: AttentionEventSource, presence: AttentionPresence = .active,
        appName: String? = nil, bundleID: String? = nil, windowTitle: String? = nil,
        url: String? = nil, domain: String? = nil, faviconURL: String? = nil,
        browserProfile: String? = nil, media: AttentionMedia? = nil
    ) {
        self.id = id
        self.startedAt = startedAt
        self.duration = max(0, duration)
        self.source = source
        self.presence = presence
        self.appName = appName
        self.bundleID = bundleID
        self.windowTitle = windowTitle
        self.url = url
        self.domain = domain
        self.faviconURL = faviconURL
        self.browserProfile = browserProfile
        self.media = media
    }

    public var endedAt: Date { startedAt.addingTimeInterval(duration) }

    public var isPrimaryAttention: Bool {
        source == .application || source == .browser
    }

    public func clipped(from: Date, to: Date) -> AttentionEvent? {
        let start = max(startedAt, from)
        let end = min(endedAt, to)
        guard end > start else { return nil }
        var copy = self
        copy.startedAt = start
        copy.duration = end.timeIntervalSince(start)
        return copy
    }

    public func canMerge(with next: AttentionEvent, pulseTime: TimeInterval) -> Bool {
        guard source == next.source, presence == next.presence, appName == next.appName,
            bundleID == next.bundleID, windowTitle == next.windowTitle, url == next.url,
            domain == next.domain, browserProfile == next.browserProfile, media == next.media
        else { return false }
        return next.startedAt.timeIntervalSince(endedAt) <= pulseTime
            && next.startedAt.timeIntervalSince(endedAt) >= -pulseTime
    }

    public func merged(with next: AttentionEvent) -> AttentionEvent {
        var copy = self
        let end = max(endedAt, next.endedAt)
        copy.duration = end.timeIntervalSince(startedAt)
        copy.faviconURL = next.faviconURL ?? faviconURL
        return copy
    }
}

public struct AttentionCategory: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var kind: AttentionCategoryKind
    public var color: String

    public init(id: String, name: String, kind: AttentionCategoryKind, color: String) {
        self.id = id
        self.name = name
        self.kind = kind
        self.color = color
    }
}

public struct AttentionIdentityRule: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var categoryID: String
    public var bundleIDs: [String]
    public var domains: [String]

    public init(
        id: String = UUID().uuidString, name: String, categoryID: String,
        bundleIDs: [String] = [], domains: [String] = []
    ) {
        self.id = id
        self.name = name
        self.categoryID = categoryID
        self.bundleIDs = bundleIDs
        self.domains = domains
    }
}

public struct AttentionSettings: Codable, Equatable, Sendable {
    public var trackingEnabled: Bool
    public var browserTrackingEnabled: Bool
    public var idleThreshold: TimeInterval
    public var privacyLevel: AttentionPrivacyLevel
    public var windowTitlesEnabled: Bool
    public var iCloudBackupEnabled: Bool
    public var serverPort: UInt16
    public var serverToken: String
    public var categories: [AttentionCategory]
    public var rules: [AttentionIdentityRule]

    public init(
        trackingEnabled: Bool = false, browserTrackingEnabled: Bool = false,
        idleThreshold: TimeInterval = 300, privacyLevel: AttentionPrivacyLevel = .domains,
        windowTitlesEnabled: Bool = false, iCloudBackupEnabled: Bool = false,
        serverPort: UInt16 = 52728, serverToken: String = UUID().uuidString,
        categories: [AttentionCategory] = AttentionSettings.defaultCategories,
        rules: [AttentionIdentityRule] = AttentionSettings.defaultRules
    ) {
        self.trackingEnabled = trackingEnabled
        self.browserTrackingEnabled = browserTrackingEnabled
        self.idleThreshold = idleThreshold
        self.privacyLevel = privacyLevel
        self.windowTitlesEnabled = windowTitlesEnabled
        self.iCloudBackupEnabled = iCloudBackupEnabled
        self.serverPort = serverPort
        self.serverToken = serverToken
        self.categories = categories
        self.rules = rules
    }

    public static let defaultCategories = [
        AttentionCategory(id: "focus", name: "Focused work", kind: .focus, color: "5B8FF9"),
        AttentionCategory(
            id: "communication", name: "Communication", kind: .communication, color: "61DDAA"),
        AttentionCategory(
            id: "entertainment", name: "Entertainment", kind: .entertainment, color: "F6BD16"),
        AttentionCategory(id: "neutral", name: "Neutral", kind: .neutral, color: "65789B"),
        AttentionCategory(
            id: "unclassified", name: "Unclassified", kind: .unclassified, color: "A0A7B4"),
    ]

    public static let defaultRules = [
        AttentionIdentityRule(
            name: "WhatsApp", categoryID: "communication",
            bundleIDs: ["net.whatsapp.WhatsApp", "net.whatsapp.WhatsAppSMB"],
            domains: ["web.whatsapp.com"]),
        AttentionIdentityRule(
            name: "Slack", categoryID: "communication",
            bundleIDs: ["com.tinyspeck.slackmacgap"], domains: ["app.slack.com"]),
        AttentionIdentityRule(
            name: "Discord", categoryID: "communication",
            bundleIDs: ["com.hnc.Discord"], domains: ["discord.com"]),
        AttentionIdentityRule(
            name: "Spotify", categoryID: "entertainment",
            bundleIDs: ["com.spotify.client"], domains: ["open.spotify.com"]),
        AttentionIdentityRule(
            name: "YouTube", categoryID: "entertainment", domains: ["youtube.com"]),
        AttentionIdentityRule(
            name: "Netflix", categoryID: "entertainment", domains: ["netflix.com"]),
        AttentionIdentityRule(
            name: "Prime Video", categoryID: "entertainment",
            domains: ["primevideo.com"]),
    ]
}

public struct AttentionFocusSession: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var startedAt: Date
    public var plannedDuration: TimeInterval
    public var endedAt: Date?

    public init(
        id: String = UUID().uuidString, name: String, startedAt: Date = Date(),
        plannedDuration: TimeInterval, endedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.startedAt = startedAt
        self.plannedDuration = plannedDuration
        self.endedAt = endedAt
    }
}

public struct AttentionEntity: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var category: AttentionCategory
    public var source: AttentionEventSource
    public var duration: TimeInterval
    public var faviconURL: String?

    public init(
        id: String, name: String, category: AttentionCategory, source: AttentionEventSource,
        duration: TimeInterval, faviconURL: String? = nil
    ) {
        self.id = id
        self.name = name
        self.category = category
        self.source = source
        self.duration = duration
        self.faviconURL = faviconURL
    }
}

public struct AttentionMusicSummary: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var artist: String?
    public var album: String?
    public var service: String
    public var duration: TimeInterval

    public init(
        id: String, title: String, artist: String?, album: String?, service: String,
        duration: TimeInterval
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.service = service
        self.duration = duration
    }
}

public struct AttentionSummary: Codable, Equatable, Sendable {
    public var from: Date
    public var to: Date
    public var activeDuration: TimeInterval
    public var idleDuration: TimeInterval
    public var focusedDuration: TimeInterval
    public var communicationDuration: TimeInterval
    public var entertainmentDuration: TimeInterval
    public var contextSwitches: Int
    public var entities: [AttentionEntity]
    public var music: [AttentionMusicSummary]

    public init(
        from: Date, to: Date, activeDuration: TimeInterval, idleDuration: TimeInterval,
        focusedDuration: TimeInterval, communicationDuration: TimeInterval,
        entertainmentDuration: TimeInterval, contextSwitches: Int,
        entities: [AttentionEntity], music: [AttentionMusicSummary]
    ) {
        self.from = from
        self.to = to
        self.activeDuration = activeDuration
        self.idleDuration = idleDuration
        self.focusedDuration = focusedDuration
        self.communicationDuration = communicationDuration
        self.entertainmentDuration = entertainmentDuration
        self.contextSwitches = contextSwitches
        self.entities = entities
        self.music = music
    }
}
