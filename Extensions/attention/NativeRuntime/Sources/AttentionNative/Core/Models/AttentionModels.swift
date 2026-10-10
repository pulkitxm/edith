@_implementationOnly import EdithExtensionSupport_attention_native
@_implementationOnly import EdithExtensionUI_attention_native
import Foundation

enum AttentionEventSource: String, Codable, CaseIterable, Sendable {
    case application
    case browser
    case media
    case manual
    case agent
}

enum AttentionPresence: String, Codable, CaseIterable, Sendable {
    case active
    case idle
    case locked
}

enum AttentionPrivacyLevel: String, Codable, CaseIterable, Sendable {
    case applications
    case domains
    case detailed
}

enum AttentionProductivity: Int, Codable, CaseIterable, Comparable, Sendable {
    case veryDistracting = -2
    case distracting = -1
    case neutral = 0
    case productive = 1
    case veryProductive = 2

    static let ranked: [AttentionProductivity] = [
        .veryProductive, .productive, .neutral, .distracting, .veryDistracting,
    ]

    static func < (lhs: AttentionProductivity, rhs: AttentionProductivity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var key: String { String(rawValue) }

    var identifier: String {
        switch self {
        case .veryDistracting: "very_distracting"
        case .distracting: "distracting"
        case .neutral: "neutral"
        case .productive: "productive"
        case .veryProductive: "very_productive"
        }
    }

    init?(identifier: String) {
        guard let match = Self.allCases.first(where: { $0.identifier == identifier }) else {
            return nil
        }
        self = match
    }

    var title: String {
        switch self {
        case .veryDistracting: "Very distracting"
        case .distracting: "Distracting"
        case .neutral: "Neutral"
        case .productive: "Productive"
        case .veryProductive: "Very productive"
        }
    }

    var meaning: String {
        switch self {
        case .veryDistracting: "pulls attention away from goals for no real return"
        case .distracting: "mostly leisure or habit with little lasting value"
        case .neutral: "necessary overhead, neither advancing nor hurting goals"
        case .productive: "supports goals, such as learning, coordination or light work"
        case .veryProductive: "directly produces work, such as building, writing or designing"
        }
    }

    var weight: Double { Double(rawValue + 2) }

    init(key: String) {
        self = Int(key).flatMap(AttentionProductivity.init(rawValue:)) ?? .neutral
    }
}

enum AttentionSphere: String, Codable, CaseIterable, Sendable {
    case work
    case personal
    case both

    var title: String {
        switch self {
        case .work: "Work"
        case .personal: "Personal"
        case .both: "Work and personal"
        }
    }
}

enum AttentionTag {
    static let page = "page"
    static let machine = "machine"
    static let agent = "agent"
    static let project = "project"
    static let session = "session"
    static let view = "view"
    static let status = "status"
    static let repository = "repo"
    static let section = "section"
    static let search = "search"
    static let video = "video"
    static let channel = "channel"
    static let group = "group"
    static let document = "doc"
    static let track = "track"
    static let passive = "passive"
    static let site = "site"
    static let about = "about"

    static let domainSafe: Set<String> = [passive]

    static let edithSafe: Set<String> = [page, machine, agent, view, status]

    static func filtered(
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

    static let dimensions = [
        page, machine, agent, project, repository, section, channel, group, search, document,
    ]

    static func title(_ key: String) -> String {
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

struct AttentionSignals: Codable, Equatable, Sendable {
    var keys: Int
    var clicks: Int
    var scrolls: Int
    var tabs: Int?

    init(keys: Int = 0, clicks: Int = 0, scrolls: Int = 0, tabs: Int? = nil) {
        self.keys = max(0, keys)
        self.clicks = max(0, clicks)
        self.scrolls = max(0, scrolls)
        self.tabs = tabs
    }

    var isEmpty: Bool { keys == 0 && clicks == 0 && scrolls == 0 && tabs == nil }

    var interactions: Int { keys + clicks + scrolls }

    func adding(_ other: AttentionSignals?) -> AttentionSignals {
        guard let other else { return self }
        let tabs = [self.tabs, other.tabs].compactMap { $0 }.max()
        return AttentionSignals(
            keys: keys &+ other.keys, clicks: clicks &+ other.clicks,
            scrolls: scrolls &+ other.scrolls, tabs: tabs)
    }
}

struct AttentionMedia: Codable, Equatable, Sendable {
    var title: String
    var artist: String?
    var album: String?
    var service: String
    var kind: String
    var playing: Bool

    init(
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

struct AttentionAudibleTab: Codable, Equatable, Sendable {
    var id: UUID
    var timestamp: Date
    var duration: TimeInterval
    var title: String
    var url: String?
    var domain: String?
    var kind: String

    init(
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

struct AttentionBrowserHeartbeat: Codable, Equatable, Sendable {
    var id: UUID
    var timestamp: Date
    var duration: TimeInterval
    var presence: AttentionPresence
    var appName: String
    var bundleID: String?
    var url: String?
    var domain: String?
    var title: String?
    var faviconURL: String?
    var browserProfile: String?
    var media: [AttentionMedia]
    var tags: [String: String]?
    var signals: AttentionSignals?
    var audible: [AttentionAudibleTab]?

    init(
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

struct AttentionHistoryVisit: Codable, Equatable, Sendable {
    var url: String
    var title: String?
    var lastVisitedAt: Date
    var visitCount: Int
    var typedCount: Int
    var profile: String

    init(
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

struct AttentionHistoryImport: Codable, Equatable, Sendable {
    var profile: String
    var visits: [AttentionHistoryVisit]

    init(profile: String, visits: [AttentionHistoryVisit]) {
        self.profile = profile
        self.visits = visits
    }
}

struct AttentionEvent: Codable, Equatable, Identifiable, Sendable {
    static let segmentPrefixes = ["browser:", "media:", "agent:"]

    var id: String
    var startedAt: Date
    var duration: TimeInterval
    var source: AttentionEventSource
    var presence: AttentionPresence
    var appName: String?
    var bundleID: String?
    var windowTitle: String?
    var url: String?
    var domain: String?
    var faviconURL: String?
    var browserProfile: String?
    var media: AttentionMedia?
    var tags: [String: String]?
    var signals: AttentionSignals?

    init(
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

    var endedAt: Date { startedAt.addingTimeInterval(duration) }

    var isPrimaryAttention: Bool {
        source == .application || source == .browser
    }

    var isSegment: Bool {
        Self.segmentPrefixes.contains { id.hasPrefix($0) }
    }

    func tag(_ key: String) -> String? {
        tags?[key]
    }

    func clipped(from: Date, to: Date) -> AttentionEvent? {
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

    func canMerge(with next: AttentionEvent, pulseTime: TimeInterval) -> Bool {
        guard source == next.source, presence == next.presence, appName == next.appName,
            bundleID == next.bundleID, windowTitle == next.windowTitle, url == next.url,
            domain == next.domain, browserProfile == next.browserProfile, media == next.media,
            (tags ?? [:]) == (next.tags ?? [:])
        else { return false }
        return next.startedAt.timeIntervalSince(endedAt) <= pulseTime
            && next.startedAt.timeIntervalSince(endedAt) >= -pulseTime
    }

    func merged(with next: AttentionEvent) -> AttentionEvent {
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

struct AttentionCategory: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var productivity: AttentionProductivity
    var sphere: AttentionSphere

    init(
        id: String, name: String, productivity: AttentionProductivity = .neutral,
        sphere: AttentionSphere = .both
    ) {
        self.id = id
        self.name = name
        self.productivity = productivity
        self.sphere = sphere
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, productivity, sphere, kind
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let identifier = try container.decode(String.self, forKey: .id)
        id = identifier
        name = try container.decode(String.self, forKey: .name)
        let builtIn = AttentionCatalog.categories.first { $0.id == identifier }
        let legacy: AttentionProductivity? =
            switch try container.decodeIfPresent(String.self, forKey: .kind) {
            case "focus": .productive
            case "entertainment": .distracting
            case .some: .neutral
            case .none: nil
            }
        productivity =
            try container.decodeIfPresent(AttentionProductivity.self, forKey: .productivity)
            ?? builtIn?.productivity ?? legacy ?? .neutral
        sphere =
            try container.decodeIfPresent(AttentionSphere.self, forKey: .sphere)
            ?? builtIn?.sphere ?? .both
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(productivity, forKey: .productivity)
        try container.encode(sphere, forKey: .sphere)
    }

    var isUnclassified: Bool { id == AttentionCatalog.unclassified }
}

struct AttentionIdentityRule: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var categoryID: String
    var bundleIDs: [String]
    var domains: [String]
    var urls: [String]
    var keywords: [String]
    var contexts: [String]
    var browserProfiles: [String]
    var reportSeparately: Bool
    var productivity: AttentionProductivity?
    var sphere: AttentionSphere?

    init(
        id: String = UUID().uuidString, name: String, categoryID: String,
        bundleIDs: [String] = [], domains: [String] = [], urls: [String] = [],
        keywords: [String] = [], contexts: [String] = [],
        browserProfiles: [String] = [], reportSeparately: Bool = false,
        productivity: AttentionProductivity? = nil, sphere: AttentionSphere? = nil
    ) {
        self.id = id
        self.name = name
        self.categoryID = categoryID
        self.bundleIDs = bundleIDs
        self.domains = domains
        self.urls = urls
        self.keywords = keywords
        self.contexts = contexts
        self.browserProfiles = browserProfiles
        self.reportSeparately = reportSeparately
        self.productivity = productivity
        self.sphere = sphere
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, categoryID, bundleIDs, domains, urls, keywords, contexts, browserProfiles,
            reportSeparately, productivity,
            sphere
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        categoryID = try container.decode(String.self, forKey: .categoryID)
        bundleIDs = try container.decodeIfPresent([String].self, forKey: .bundleIDs) ?? []
        domains = try container.decodeIfPresent([String].self, forKey: .domains) ?? []
        urls = try container.decodeIfPresent([String].self, forKey: .urls) ?? []
        keywords = try container.decodeIfPresent([String].self, forKey: .keywords) ?? []
        contexts = try container.decodeIfPresent([String].self, forKey: .contexts) ?? []
        browserProfiles =
            try container.decodeIfPresent([String].self, forKey: .browserProfiles) ?? []
        reportSeparately =
            try container.decodeIfPresent(Bool.self, forKey: .reportSeparately) ?? false
        productivity = try container.decodeIfPresent(
            AttentionProductivity.self, forKey: .productivity)
        sphere = try container.decodeIfPresent(AttentionSphere.self, forKey: .sphere)
    }

    var isIdentity: Bool {
        (!bundleIDs.isEmpty || !domains.isEmpty) && urls.isEmpty && keywords.isEmpty
            && contexts.isEmpty && browserProfiles.isEmpty
    }

    var isEmpty: Bool {
        bundleIDs.isEmpty && domains.isEmpty && urls.isEmpty && keywords.isEmpty
            && contexts.isEmpty && browserProfiles.isEmpty
    }

    var specificity: Int {
        (urls.isEmpty ? 0 : 32) + (keywords.isEmpty ? 0 : 8) + (contexts.isEmpty ? 0 : 8)
            + (browserProfiles.isEmpty ? 0 : 4)
            + (bundleIDs.isEmpty && domains.isEmpty ? 0 : 1)
    }
}

struct AttentionSettings: Codable, Equatable, Sendable {
    var isEnabled: Bool
    var trackingEnabled: Bool
    var browserTrackingEnabled: Bool
    var idleThreshold: TimeInterval
    var privacyLevel: AttentionPrivacyLevel
    var windowTitlesEnabled: Bool
    var iCloudBackupEnabled: Bool
    var serverPort: UInt16
    var serverToken: String
    var categories: [AttentionCategory]
    var rules: [AttentionIdentityRule]
    var agentTrackingEnabled: Bool
    var mediaTrackingEnabled: Bool
    var jevCategorizationEnabled: Bool
    var focusBlockMinimum: TimeInterval
    var ignoredBundleIDs: [String]
    var profileNote: String

    init(
        isEnabled: Bool = false, trackingEnabled: Bool = false,
        browserTrackingEnabled: Bool = false,
        idleThreshold: TimeInterval = 300,
        privacyLevel: AttentionPrivacyLevel = .detailed,
        windowTitlesEnabled: Bool = true, iCloudBackupEnabled: Bool = false,
        serverPort: UInt16 = 52728, serverToken: String = UUID().uuidString,
        categories: [AttentionCategory] = AttentionCatalog.categories,
        rules: [AttentionIdentityRule] = [], agentTrackingEnabled: Bool = true,
        mediaTrackingEnabled: Bool = true, jevCategorizationEnabled: Bool = true,
        focusBlockMinimum: TimeInterval = 1_500, ignoredBundleIDs: [String] = [],
        profileNote: String = ""
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
        self.profileNote = profileNote
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
        case profileNote
    }

    init(from decoder: Decoder) throws {
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
        profileNote = try container.decodeIfPresent(String.self, forKey: .profileNote) ?? ""
        normalizeCategories()
    }

    mutating func normalizeCategories() {
        var seen = Set<String>()
        categories = categories.filter { seen.insert($0.id).inserted }
        for category in AttentionCatalog.categories where !seen.contains(category.id) {
            categories.append(category)
            seen.insert(category.id)
        }
    }

    func category(_ id: String) -> AttentionCategory {
        categories.first { $0.id == id } ?? categories.first {
            $0.id == AttentionCatalog.unclassified
        }
            ?? AttentionCatalog.categories.last!
    }
}

struct AttentionFocusSession: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var startedAt: Date
    var plannedDuration: TimeInterval
    var endedAt: Date?

    init(
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

struct AttentionAppContext: Codable, Equatable, Sendable {
    var bundleID: String
    var tags: [String: String]
    var windowTitle: String?

    init(bundleID: String, tags: [String: String], windowTitle: String? = nil) {
        self.bundleID = bundleID
        self.tags = tags
        self.windowTitle = windowTitle
    }
}
