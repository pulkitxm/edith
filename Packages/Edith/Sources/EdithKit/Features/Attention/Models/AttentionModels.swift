import Foundation

public enum AttentionEventSource: String, Codable, CaseIterable, Sendable {
    case application
    case browser
    case media
    case manual
    case agent
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

    public var title: String {
        switch self {
        case .focus: "Productive"
        case .communication: "Communication"
        case .entertainment: "Distracting"
        case .neutral: "Neutral"
        case .unclassified: "Unclassified"
        }
    }
}

public enum AttentionTag {
    public static let page = "page"
    public static let machine = "machine"
    public static let agent = "agent"
    public static let project = "project"
    public static let session = "session"
    public static let view = "view"
    public static let status = "status"
    public static let repository = "repo"
    public static let section = "section"
    public static let search = "search"
    public static let video = "video"
    public static let channel = "channel"
    public static let group = "group"
    public static let document = "doc"
    public static let track = "track"
    public static let passive = "passive"

    public static let domainSafe: Set<String> = [passive]

    public static let edithSafe: Set<String> = [page, machine, agent, view, status]

    public static func filtered(
        _ tags: [String: String]?, privacyLevel: AttentionPrivacyLevel,
        allowed: Set<String> = domainSafe
    ) -> [String: String]? {
        guard let tags else { return nil }
        switch privacyLevel {
        case .detailed: return tags
        case .domains: return tags.filter { allowed.contains($0.key) }
        case .applications: return nil
        }
    }

    public static let dimensions = [
        page, machine, agent, project, repository, section, channel, group, search, document,
    ]

    public static func title(_ key: String) -> String {
        switch key {
        case page: "Edith page"
        case machine: "Machine"
        case agent: "Agent"
        case project: "Project"
        case session: "Session"
        case view: "View"
        case status: "Status"
        case repository: "Repository"
        case section: "Site section"
        case search: "Search"
        case video: "Video"
        case channel: "Channel"
        case group: "Tab group"
        case document: "Doc"
        case track: "Track"
        default: key.capitalized
        }
    }
}

public struct AttentionSignals: Codable, Equatable, Sendable {
    public var keys: Int
    public var clicks: Int
    public var scrolls: Int
    public var tabs: Int?

    public init(keys: Int = 0, clicks: Int = 0, scrolls: Int = 0, tabs: Int? = nil) {
        self.keys = max(0, keys)
        self.clicks = max(0, clicks)
        self.scrolls = max(0, scrolls)
        self.tabs = tabs
    }

    public var isEmpty: Bool { keys == 0 && clicks == 0 && scrolls == 0 && tabs == nil }

    public var interactions: Int { keys + clicks + scrolls }

    public func adding(_ other: AttentionSignals?) -> AttentionSignals {
        guard let other else { return self }
        let tabs = [self.tabs, other.tabs].compactMap { $0 }.max()
        return AttentionSignals(
            keys: keys &+ other.keys, clicks: clicks &+ other.clicks,
            scrolls: scrolls &+ other.scrolls, tabs: tabs)
    }
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

public struct AttentionAudibleTab: Codable, Equatable, Sendable {
    public var id: UUID
    public var timestamp: Date
    public var duration: TimeInterval
    public var title: String
    public var url: String?
    public var domain: String?
    public var kind: String

    public init(
        id: UUID = UUID(), timestamp: Date, duration: TimeInterval, title: String,
        url: String? = nil, domain: String? = nil, kind: String = "audio"
    ) {
        self.id = id
        self.timestamp = timestamp
        self.duration = duration
        self.title = title
        self.url = url
        self.domain = domain
        self.kind = kind
    }
}

public struct AttentionBrowserHeartbeat: Codable, Equatable, Sendable {
    public var id: UUID
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
    public var tags: [String: String]?
    public var signals: AttentionSignals?
    public var audible: [AttentionAudibleTab]?

    public init(
        id: UUID = UUID(), timestamp: Date, duration: TimeInterval, presence: AttentionPresence,
        appName: String, bundleID: String? = nil, url: String? = nil,
        domain: String? = nil, title: String? = nil, faviconURL: String? = nil,
        browserProfile: String? = nil, media: [AttentionMedia] = [],
        tags: [String: String]? = nil, signals: AttentionSignals? = nil,
        audible: [AttentionAudibleTab]? = nil
    ) {
        self.id = id
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
        self.tags = tags
        self.signals = signals
        self.audible = audible
    }
}

public struct AttentionHistoryVisit: Codable, Equatable, Sendable {
    public var url: String
    public var title: String?
    public var lastVisitedAt: Date
    public var visitCount: Int
    public var typedCount: Int
    public var profile: String

    public init(
        url: String, title: String? = nil, lastVisitedAt: Date, visitCount: Int,
        typedCount: Int, profile: String
    ) {
        self.url = url
        self.title = title
        self.lastVisitedAt = lastVisitedAt
        self.visitCount = visitCount
        self.typedCount = typedCount
        self.profile = profile
    }
}

public struct AttentionHistoryImport: Codable, Equatable, Sendable {
    public var profile: String
    public var visits: [AttentionHistoryVisit]

    public init(profile: String, visits: [AttentionHistoryVisit]) {
        self.profile = profile
        self.visits = visits
    }
}

public struct AttentionEvent: Codable, Equatable, Identifiable, Sendable {
    public static let segmentPrefixes = ["browser:", "media:", "agent:"]

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
    public var tags: [String: String]?
    public var signals: AttentionSignals?

    public init(
        id: String = UUID().uuidString, startedAt: Date, duration: TimeInterval,
        source: AttentionEventSource, presence: AttentionPresence = .active,
        appName: String? = nil, bundleID: String? = nil, windowTitle: String? = nil,
        url: String? = nil, domain: String? = nil, faviconURL: String? = nil,
        browserProfile: String? = nil, media: AttentionMedia? = nil,
        tags: [String: String]? = nil, signals: AttentionSignals? = nil
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
        self.tags = tags?.isEmpty == true ? nil : tags
        self.signals = signals?.isEmpty == true ? nil : signals
    }

    public var endedAt: Date { startedAt.addingTimeInterval(duration) }

    public var isPrimaryAttention: Bool {
        source == .application || source == .browser
    }

    public var isSegment: Bool {
        Self.segmentPrefixes.contains { id.hasPrefix($0) }
    }

    public func tag(_ key: String) -> String? {
        tags?[key]
    }

    public func clipped(from: Date, to: Date) -> AttentionEvent? {
        let start = max(startedAt, from)
        let end = min(endedAt, to)
        guard end > start else { return nil }
        var copy = self
        if duration > 0, let signals, end.timeIntervalSince(start) < duration {
            let low = max(0, min(1, start.timeIntervalSince(startedAt) / duration))
            let high = max(0, min(1, end.timeIntervalSince(startedAt) / duration))
            func portion(_ value: Int) -> Int {
                Int((Double(value) * high).rounded(.down))
                    - Int((Double(value) * low).rounded(.down))
            }
            copy.signals = AttentionSignals(
                keys: portion(signals.keys), clicks: portion(signals.clicks),
                scrolls: portion(signals.scrolls), tabs: signals.tabs)
        }
        copy.startedAt = start
        copy.duration = end.timeIntervalSince(start)
        return copy
    }

    public func canMerge(with next: AttentionEvent, pulseTime: TimeInterval) -> Bool {
        guard source == next.source, presence == next.presence, appName == next.appName,
            bundleID == next.bundleID, windowTitle == next.windowTitle, url == next.url,
            domain == next.domain, browserProfile == next.browserProfile, media == next.media,
            (tags ?? [:]) == (next.tags ?? [:])
        else { return false }
        return next.startedAt.timeIntervalSince(endedAt) <= pulseTime
            && next.startedAt.timeIntervalSince(endedAt) >= -pulseTime
    }

    public func merged(with next: AttentionEvent) -> AttentionEvent {
        var copy = self
        let end = max(endedAt, next.endedAt)
        copy.duration = end.timeIntervalSince(startedAt)
        copy.faviconURL = next.faviconURL ?? faviconURL
        if let signals = next.signals {
            copy.signals = (copy.signals ?? AttentionSignals()).adding(signals)
        }
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
    public var urls: [String]
    public var keywords: [String]
    public var contexts: [String]

    public init(
        id: String = UUID().uuidString, name: String, categoryID: String,
        bundleIDs: [String] = [], domains: [String] = [], urls: [String] = [],
        keywords: [String] = [], contexts: [String] = []
    ) {
        self.id = id
        self.name = name
        self.categoryID = categoryID
        self.bundleIDs = bundleIDs
        self.domains = domains
        self.urls = urls
        self.keywords = keywords
        self.contexts = contexts
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, categoryID, bundleIDs, domains, urls, keywords, contexts
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        categoryID = try container.decode(String.self, forKey: .categoryID)
        bundleIDs = try container.decodeIfPresent([String].self, forKey: .bundleIDs) ?? []
        domains = try container.decodeIfPresent([String].self, forKey: .domains) ?? []
        urls = try container.decodeIfPresent([String].self, forKey: .urls) ?? []
        keywords = try container.decodeIfPresent([String].self, forKey: .keywords) ?? []
        contexts = try container.decodeIfPresent([String].self, forKey: .contexts) ?? []
    }

    public var isIdentity: Bool {
        (!bundleIDs.isEmpty || !domains.isEmpty) && urls.isEmpty && keywords.isEmpty
            && contexts.isEmpty
    }

    public var isEmpty: Bool {
        bundleIDs.isEmpty && domains.isEmpty && urls.isEmpty && keywords.isEmpty
            && contexts.isEmpty
    }

    public var specificity: Int {
        (urls.isEmpty ? 0 : 8) + (keywords.isEmpty ? 0 : 8) + (contexts.isEmpty ? 0 : 8)
            + (bundleIDs.isEmpty && domains.isEmpty ? 0 : 1)
    }
}

public struct AttentionSettings: Codable, Equatable, Sendable {
    public var isEnabled: Bool
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
    public var agentTrackingEnabled: Bool
    public var mediaTrackingEnabled: Bool
    public var jevCategorizationEnabled: Bool
    public var focusBlockMinimum: TimeInterval
    public var ignoredBundleIDs: [String]

    public init(
        isEnabled: Bool = false, trackingEnabled: Bool = false,
        browserTrackingEnabled: Bool = false,
        idleThreshold: TimeInterval = 300, privacyLevel: AttentionPrivacyLevel = .detailed,
        windowTitlesEnabled: Bool = true, iCloudBackupEnabled: Bool = false,
        serverPort: UInt16 = 52728, serverToken: String = UUID().uuidString,
        categories: [AttentionCategory] = AttentionCatalog.categories,
        rules: [AttentionIdentityRule] = [], agentTrackingEnabled: Bool = true,
        mediaTrackingEnabled: Bool = true, jevCategorizationEnabled: Bool = true,
        focusBlockMinimum: TimeInterval = 1_500, ignoredBundleIDs: [String] = []
    ) {
        self.isEnabled = isEnabled
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
        self.agentTrackingEnabled = agentTrackingEnabled
        self.mediaTrackingEnabled = mediaTrackingEnabled
        self.jevCategorizationEnabled = jevCategorizationEnabled
        self.focusBlockMinimum = focusBlockMinimum
        self.ignoredBundleIDs = ignoredBundleIDs
        normalizeCategories()
    }

    private enum CodingKeys: String, CodingKey {
        case isEnabled = "enabled"
        case trackingEnabled
        case browserTrackingEnabled
        case idleThreshold
        case privacyLevel
        case windowTitlesEnabled
        case iCloudBackupEnabled
        case serverPort
        case serverToken
        case categories
        case rules
        case agentTrackingEnabled
        case mediaTrackingEnabled
        case jevCategorizationEnabled
        case focusBlockMinimum
        case ignoredBundleIDs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        trackingEnabled = try container.decode(Bool.self, forKey: .trackingEnabled)
        browserTrackingEnabled = try container.decode(Bool.self, forKey: .browserTrackingEnabled)
        isEnabled =
            try container.decodeIfPresent(Bool.self, forKey: .isEnabled)
            ?? (trackingEnabled || browserTrackingEnabled)
        idleThreshold = try container.decode(TimeInterval.self, forKey: .idleThreshold)
        privacyLevel = try container.decode(AttentionPrivacyLevel.self, forKey: .privacyLevel)
        windowTitlesEnabled = try container.decode(Bool.self, forKey: .windowTitlesEnabled)
        iCloudBackupEnabled = try container.decode(Bool.self, forKey: .iCloudBackupEnabled)
        serverPort = try container.decode(UInt16.self, forKey: .serverPort)
        serverToken = try container.decode(String.self, forKey: .serverToken)
        categories = try container.decode([AttentionCategory].self, forKey: .categories)
        rules = try container.decode([AttentionIdentityRule].self, forKey: .rules)
        agentTrackingEnabled =
            try container.decodeIfPresent(Bool.self, forKey: .agentTrackingEnabled) ?? true
        mediaTrackingEnabled =
            try container.decodeIfPresent(Bool.self, forKey: .mediaTrackingEnabled) ?? true
        jevCategorizationEnabled =
            try container.decodeIfPresent(Bool.self, forKey: .jevCategorizationEnabled) ?? true
        focusBlockMinimum =
            try container.decodeIfPresent(TimeInterval.self, forKey: .focusBlockMinimum) ?? 1_500
        ignoredBundleIDs =
            try container.decodeIfPresent([String].self, forKey: .ignoredBundleIDs) ?? []
        normalizeCategories()
    }

    public mutating func normalizeCategories() {
        var seen = Set<String>()
        categories = categories.filter { seen.insert($0.id).inserted }
        for category in AttentionCatalog.categories where !seen.contains(category.id) {
            categories.append(category)
            seen.insert(category.id)
        }
    }

    public func category(_ id: String) -> AttentionCategory {
        categories.first { $0.id == id } ?? categories.first {
            $0.id == AttentionCatalog.unclassified
        }
            ?? AttentionCatalog.categories.last!
    }
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

public struct AttentionAppContext: Codable, Equatable, Sendable {
    public var bundleID: String
    public var tags: [String: String]
    public var windowTitle: String?

    public init(bundleID: String, tags: [String: String], windowTitle: String? = nil) {
        self.bundleID = bundleID
        self.tags = tags
        self.windowTitle = windowTitle
    }
}
