import Foundation

public enum AttentionCategorySource: String, Codable, Sendable {
    case user
    case catalog
    case jev
    case none
}

public struct AttentionDetail: Codable, Equatable, Identifiable, Sendable {
    public var id: String { name }
    public var name: String
    public var url: String?
    public var duration: TimeInterval
    public var categoryID: String
    public var productivity: AttentionProductivity

    public init(
        name: String, url: String? = nil, duration: TimeInterval, categoryID: String,
        productivity: AttentionProductivity = .neutral
    ) {
        self.name = name
        self.url = url
        self.duration = duration
        self.categoryID = categoryID
        self.productivity = productivity
    }
}

public struct AttentionEntity: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var category: AttentionCategory
    public var source: AttentionEventSource
    public var duration: TimeInterval
    public var bundleID: String?
    public var faviconURL: String?
    public var domain: String?
    public var categoryDurations: [String: TimeInterval]
    public var categorySource: AttentionCategorySource
    public var confidence: Double?
    public var details: [AttentionDetail]
    public var signals: AttentionSignals
    public var visits: Int
    public var productivity: AttentionProductivity
    public var sphere: AttentionSphere
    public var levels: [String: TimeInterval]
    public var about: String?

    public init(
        id: String, name: String, category: AttentionCategory, source: AttentionEventSource,
        duration: TimeInterval, bundleID: String? = nil, faviconURL: String? = nil,
        domain: String? = nil, categoryDurations: [String: TimeInterval] = [:],
        categorySource: AttentionCategorySource = .none, confidence: Double? = nil,
        details: [AttentionDetail] = [], signals: AttentionSignals = AttentionSignals(),
        visits: Int = 0, productivity: AttentionProductivity? = nil,
        sphere: AttentionSphere? = nil, levels: [String: TimeInterval] = [:]
    ) {
        self.id = id
        self.name = name
        self.category = category
        self.source = source
        self.duration = duration
        self.bundleID = bundleID
        self.faviconURL = faviconURL
        self.domain = domain
        self.categoryDurations = categoryDurations
        self.categorySource = categorySource
        self.confidence = confidence
        self.details = details
        self.signals = signals
        self.visits = visits
        self.productivity = productivity ?? category.productivity
        self.sphere = sphere ?? category.sphere
        self.levels = levels
    }

    public var isUnclassified: Bool { category.isUnclassified }
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

public struct AttentionCategoryTotal: Codable, Equatable, Identifiable, Sendable {
    public var id: String { category.id }
    public var category: AttentionCategory
    public var duration: TimeInterval

    public init(category: AttentionCategory, duration: TimeInterval) {
        self.category = category
        self.duration = duration
    }
}

public struct AttentionDayTotal: Codable, Equatable, Identifiable, Sendable {
    public var id: Date { day }
    public var day: Date
    public var active: TimeInterval
    public var categories: [String: TimeInterval]
    public var agentWorking: TimeInterval
    public var switches: Int
    public var levels: [String: TimeInterval]

    public init(
        day: Date, active: TimeInterval = 0, categories: [String: TimeInterval] = [:],
        agentWorking: TimeInterval = 0, switches: Int = 0, levels: [String: TimeInterval] = [:]
    ) {
        self.day = day
        self.active = active
        self.categories = categories
        self.levels = levels
        self.agentWorking = agentWorking
        self.switches = switches
    }
}

public struct AttentionHourCell: Codable, Equatable, Identifiable, Sendable {
    public var id: Int { weekday * 24 + hour }
    public var weekday: Int
    public var hour: Int
    public var levels: [String: TimeInterval]

    public init(weekday: Int, hour: Int, levels: [String: TimeInterval] = [:]) {
        self.weekday = weekday
        self.hour = hour
        self.levels = levels
    }

    public var active: TimeInterval { levels.values.reduce(0, +) }

    public var productive: TimeInterval { AttentionLevels.productive(levels) }
}

public struct AttentionSpan: Codable, Equatable, Identifiable, Sendable {
    public var id: String { "\(start.timeIntervalSinceReferenceDate)|\(entityID)" }
    public var start: Date
    public var end: Date
    public var entityID: String
    public var name: String
    public var categoryID: String
    public var detail: String?
    public var tags: [String: String]?
    public var interactions: Int
    public var productivity: AttentionProductivity
    public var sphere: AttentionSphere

    public init(
        start: Date, end: Date, entityID: String, name: String, categoryID: String,
        detail: String? = nil, tags: [String: String]? = nil, interactions: Int = 0,
        productivity: AttentionProductivity = .neutral, sphere: AttentionSphere = .both
    ) {
        self.start = start
        self.end = end
        self.entityID = entityID
        self.name = name
        self.categoryID = categoryID
        self.detail = detail
        self.tags = tags
        self.interactions = interactions
        self.productivity = productivity
        self.sphere = sphere
    }

    public var duration: TimeInterval { end.timeIntervalSince(start) }
}

public struct AttentionFocusBlock: Codable, Equatable, Identifiable, Sendable {
    public var id: Date { start }
    public var start: Date
    public var end: Date
    public var focused: TimeInterval
    public var interruptions: Int
    public var topNames: [String]

    public init(
        start: Date, end: Date, focused: TimeInterval, interruptions: Int, topNames: [String]
    ) {
        self.start = start
        self.end = end
        self.focused = focused
        self.interruptions = interruptions
        self.topNames = topNames
    }

    public var duration: TimeInterval { end.timeIntervalSince(start) }
}

public struct AttentionTransition: Codable, Equatable, Identifiable, Sendable {
    public var id: String { from + "\u{1F}" + to }
    public var from: String
    public var to: String
    public var count: Int

    public init(from: String, to: String, count: Int) {
        self.from = from
        self.to = to
        self.count = count
    }
}

public struct AttentionBreakdownRow: Codable, Equatable, Identifiable, Sendable {
    public var id: String { key }
    public var key: String
    public var duration: TimeInterval
    public var categories: [String: TimeInterval]
    public var interactions: Int
    public var entityNames: [String]
    public var levels: [String: TimeInterval]
    public var spheres: [String: TimeInterval]

    public init(
        key: String, duration: TimeInterval = 0, categories: [String: TimeInterval] = [:],
        interactions: Int = 0, entityNames: [String] = [], levels: [String: TimeInterval] = [:],
        spheres: [String: TimeInterval] = [:]
    ) {
        self.key = key
        self.duration = duration
        self.categories = categories
        self.levels = levels
        self.spheres = spheres
        self.interactions = interactions
        self.entityNames = entityNames
    }
}

public struct AttentionDimension: Codable, Equatable, Identifiable, Sendable {
    public static let title = "title"
    public static let url = "url"
    public static let entity = "entity"
    public static let category = "category"

    public var id: String { key }
    public var key: String
    public var rows: [AttentionBreakdownRow]
    public var total: TimeInterval

    public init(key: String, rows: [AttentionBreakdownRow], total: TimeInterval) {
        self.key = key
        self.rows = rows
        self.total = total
    }

    public var title: String {
        switch key {
        case Self.title: "Page and window title"
        case Self.url: "URL"
        case Self.entity: "App and site"
        case Self.category: "Category"
        default: AttentionTag.title(key)
        }
    }
}

public struct AttentionAgentTotal: Codable, Equatable, Identifiable, Sendable {
    public var id: String { key }
    public var key: String
    public var working: TimeInterval
    public var blocked: TimeInterval
    public var sessions: Int
    public var attended: TimeInterval

    public init(
        key: String, working: TimeInterval = 0, blocked: TimeInterval = 0, sessions: Int = 0,
        attended: TimeInterval = 0
    ) {
        self.key = key
        self.working = working
        self.blocked = blocked
        self.sessions = sessions
        self.attended = attended
    }
}

public struct AttentionAgentSession: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var machine: String
    public var kind: String
    public var project: String?
    public var working: TimeInterval
    public var blocked: TimeInterval
    public var lastSeen: Date

    public init(
        id: String, title: String, machine: String, kind: String, project: String?,
        working: TimeInterval, blocked: TimeInterval, lastSeen: Date
    ) {
        self.id = id
        self.title = title
        self.machine = machine
        self.kind = kind
        self.project = project
        self.working = working
        self.blocked = blocked
        self.lastSeen = lastSeen
    }
}

public struct AttentionConcurrencyPoint: Codable, Equatable, Identifiable, Sendable {
    public var id: Date { start }
    public var start: Date
    public var working: Double
    public var attention: TimeInterval

    public init(start: Date, working: Double, attention: TimeInterval) {
        self.start = start
        self.working = working
        self.attention = attention
    }
}

public struct AttentionAgentSummary: Codable, Equatable, Sendable {
    public var working: TimeInterval
    public var blocked: TimeInterval
    public var attended: TimeInterval
    public var peakConcurrent: Int
    public var machines: [AttentionAgentTotal]
    public var kinds: [AttentionAgentTotal]
    public var projects: [AttentionAgentTotal]
    public var sessions: [AttentionAgentSession]
    public var concurrency: [AttentionConcurrencyPoint]

    public init(
        working: TimeInterval = 0, blocked: TimeInterval = 0, attended: TimeInterval = 0,
        peakConcurrent: Int = 0, machines: [AttentionAgentTotal] = [],
        kinds: [AttentionAgentTotal] = [], projects: [AttentionAgentTotal] = [],
        sessions: [AttentionAgentSession] = [], concurrency: [AttentionConcurrencyPoint] = []
    ) {
        self.working = working
        self.blocked = blocked
        self.attended = attended
        self.peakConcurrent = peakConcurrent
        self.machines = machines
        self.kinds = kinds
        self.projects = projects
        self.sessions = sessions
        self.concurrency = concurrency
    }

    public var isEmpty: Bool { working == 0 && blocked == 0 && sessions.isEmpty }
}

public enum AttentionLevels {
    public static func duration(
        _ levels: [String: TimeInterval], _ level: AttentionProductivity
    ) -> TimeInterval {
        levels[level.key] ?? 0
    }

    public static func productive(_ levels: [String: TimeInterval]) -> TimeInterval {
        duration(levels, .productive) + duration(levels, .veryProductive)
    }

    public static func distracting(_ levels: [String: TimeInterval]) -> TimeInterval {
        duration(levels, .distracting) + duration(levels, .veryDistracting)
    }

    public static func pulse(_ levels: [String: TimeInterval], unclassified: TimeInterval)
        -> Double?
    {
        let classified = levels.values.reduce(0, +) - unclassified
        guard classified > 0 else { return nil }
        var weighted = AttentionProductivity.allCases.reduce(0.0) {
            $0 + $1.weight * duration(levels, $1)
        }
        weighted -= AttentionProductivity.neutral.weight * unclassified
        return max(0, min(100, weighted / (4 * classified) * 100))
    }
}

public struct AttentionTotals: Codable, Equatable, Sendable {
    public var active: TimeInterval
    public var levels: [String: TimeInterval]
    public var spheres: [String: TimeInterval]
    public var unclassified: TimeInterval
    public var deepWork: TimeInterval
    public var contextSwitches: Int
    public var agentWorking: TimeInterval

    public init(
        active: TimeInterval = 0, levels: [String: TimeInterval] = [:],
        spheres: [String: TimeInterval] = [:], unclassified: TimeInterval = 0,
        deepWork: TimeInterval = 0, contextSwitches: Int = 0, agentWorking: TimeInterval = 0
    ) {
        self.active = active
        self.levels = levels
        self.spheres = spheres
        self.unclassified = unclassified
        self.deepWork = deepWork
        self.contextSwitches = contextSwitches
        self.agentWorking = agentWorking
    }

    public var productive: TimeInterval { AttentionLevels.productive(levels) }
    public var distracting: TimeInterval { AttentionLevels.distracting(levels) }
    public var pulse: Double? { AttentionLevels.pulse(levels, unclassified: unclassified) }
}

public struct AttentionSummary: Codable, Equatable, Sendable {
    public var from: Date
    public var to: Date
    public var activeDuration: TimeInterval
    public var idleDuration: TimeInterval
    public var levels: [String: TimeInterval]
    public var spheres: [String: TimeInterval]
    public var unclassifiedDuration: TimeInterval
    public var contextSwitches: Int
    public var medianStretch: TimeInterval
    public var longestStretch: TimeInterval
    public var entities: [AttentionEntity]
    public var categories: [AttentionCategoryTotal]
    public var music: [AttentionMusicSummary]
    public var days: [AttentionDayTotal]
    public var hours: [AttentionHourCell]
    public var spans: [AttentionSpan]
    public var focusBlocks: [AttentionFocusBlock]
    public var transitions: [AttentionTransition]
    public var dimensions: [AttentionDimension]
    public var agents: AttentionAgentSummary
    public var signals: AttentionSignals
    public var previous: AttentionTotals?

    public init(
        from: Date, to: Date, activeDuration: TimeInterval = 0, idleDuration: TimeInterval = 0,
        levels: [String: TimeInterval] = [:], spheres: [String: TimeInterval] = [:],
        unclassifiedDuration: TimeInterval = 0, contextSwitches: Int = 0,
        medianStretch: TimeInterval = 0, longestStretch: TimeInterval = 0,
        entities: [AttentionEntity] = [], categories: [AttentionCategoryTotal] = [],
        music: [AttentionMusicSummary] = [], days: [AttentionDayTotal] = [],
        hours: [AttentionHourCell] = [], spans: [AttentionSpan] = [],
        focusBlocks: [AttentionFocusBlock] = [], transitions: [AttentionTransition] = [],
        dimensions: [AttentionDimension] = [], agents: AttentionAgentSummary = .init(),
        signals: AttentionSignals = .init(), previous: AttentionTotals? = nil
    ) {
        self.from = from
        self.to = to
        self.activeDuration = activeDuration
        self.idleDuration = idleDuration
        self.levels = levels
        self.spheres = spheres
        self.unclassifiedDuration = unclassifiedDuration
        self.contextSwitches = contextSwitches
        self.medianStretch = medianStretch
        self.longestStretch = longestStretch
        self.entities = entities
        self.categories = categories
        self.music = music
        self.days = days
        self.hours = hours
        self.spans = spans
        self.focusBlocks = focusBlocks
        self.transitions = transitions
        self.dimensions = dimensions
        self.agents = agents
        self.signals = signals
        self.previous = previous
    }

    public func duration(_ level: AttentionProductivity) -> TimeInterval {
        AttentionLevels.duration(levels, level)
    }

    public func duration(_ sphere: AttentionSphere) -> TimeInterval {
        spheres[sphere.rawValue] ?? 0
    }

    public var productiveDuration: TimeInterval { AttentionLevels.productive(levels) }
    public var distractingDuration: TimeInterval { AttentionLevels.distracting(levels) }
    public var pulse: Double? { AttentionLevels.pulse(levels, unclassified: unclassifiedDuration) }
    public var deepWorkDuration: TimeInterval { focusBlocks.reduce(0) { $0 + $1.duration } }

    public var totals: AttentionTotals {
        AttentionTotals(
            active: activeDuration, levels: levels, spheres: spheres,
            unclassified: unclassifiedDuration, deepWork: deepWorkDuration,
            contextSwitches: contextSwitches, agentWorking: agents.working)
    }

    public func dimension(_ key: String) -> AttentionDimension? {
        dimensions.first { $0.key == key }
    }
}
