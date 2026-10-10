@_implementationOnly import EdithExtensionSupport_attention_native
@_implementationOnly import EdithExtensionUI_attention_native
import Foundation

enum AttentionCategorySource: String, Codable, Sendable {
    case user
    case catalog
    case jev
    case none
}

struct AttentionDetail: Codable, Equatable, Identifiable, Sendable {
    var id: String {
        [name, url ?? "", categoryID, productivity.key].joined(separator: "\u{1F}")
    }
    var name: String
    var url: String?
    var duration: TimeInterval
    var categoryID: String
    var productivity: AttentionProductivity

    init(
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

struct AttentionEntity: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var category: AttentionCategory
    var source: AttentionEventSource
    var duration: TimeInterval
    var bundleID: String?
    var faviconURL: String?
    var domain: String?
    var categoryDurations: [String: TimeInterval]
    var categorySource: AttentionCategorySource
    var confidence: Double?
    var details: [AttentionDetail]
    var signals: AttentionSignals
    var visits: Int
    var productivity: AttentionProductivity
    var sphere: AttentionSphere
    var levels: [String: TimeInterval]
    var about: String?

    init(
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

    var isUnclassified: Bool { category.isUnclassified }
}

struct AttentionMusicSummary: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var title: String
    var artist: String?
    var album: String?
    var service: String
    var duration: TimeInterval

    init(
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

struct AttentionCategoryTotal: Codable, Equatable, Identifiable, Sendable {
    var id: String { category.id }
    var category: AttentionCategory
    var duration: TimeInterval

    init(category: AttentionCategory, duration: TimeInterval) {
        self.category = category
        self.duration = duration
    }
}

struct AttentionDayTotal: Codable, Equatable, Identifiable, Sendable {
    var id: Date { day }
    var day: Date
    var active: TimeInterval
    var categories: [String: TimeInterval]
    var agentWorking: TimeInterval
    var switches: Int
    var levels: [String: TimeInterval]

    init(
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

struct AttentionHourCell: Codable, Equatable, Identifiable, Sendable {
    var id: Int { weekday * 24 + hour }
    var weekday: Int
    var hour: Int
    var levels: [String: TimeInterval]

    init(weekday: Int, hour: Int, levels: [String: TimeInterval] = [:]) {
        self.weekday = weekday
        self.hour = hour
        self.levels = levels
    }

    var active: TimeInterval { levels.values.reduce(0, +) }

    var productive: TimeInterval { AttentionLevels.productive(levels) }
}

struct AttentionSpan: Codable, Equatable, Identifiable, Sendable {
    var id: String { "\(start.timeIntervalSinceReferenceDate)|\(entityID)" }
    var start: Date
    var end: Date
    var entityID: String
    var name: String
    var categoryID: String
    var detail: String?
    var tags: [String: String]?
    var interactions: Int
    var productivity: AttentionProductivity
    var sphere: AttentionSphere

    init(
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

    var duration: TimeInterval { end.timeIntervalSince(start) }
}

struct AttentionFocusBlock: Codable, Equatable, Identifiable, Sendable {
    var id: Date { start }
    var start: Date
    var end: Date
    var focused: TimeInterval
    var interruptions: Int
    var topNames: [String]

    init(
        start: Date, end: Date, focused: TimeInterval, interruptions: Int, topNames: [String]
    ) {
        self.start = start
        self.end = end
        self.focused = focused
        self.interruptions = interruptions
        self.topNames = topNames
    }

    var duration: TimeInterval { end.timeIntervalSince(start) }
}

struct AttentionTransition: Codable, Equatable, Identifiable, Sendable {
    var id: String { from + "\u{1F}" + to }
    var from: String
    var to: String
    var count: Int

    init(from: String, to: String, count: Int) {
        self.from = from
        self.to = to
        self.count = count
    }
}

struct AttentionBreakdownRow: Codable, Equatable, Identifiable, Sendable {
    var id: String { key }
    var key: String
    var duration: TimeInterval
    var categories: [String: TimeInterval]
    var interactions: Int
    var entityNames: [String]
    var entityIDs: [String]
    var levels: [String: TimeInterval]
    var spheres: [String: TimeInterval]

    init(
        key: String, duration: TimeInterval = 0, categories: [String: TimeInterval] = [:],
        interactions: Int = 0, entityNames: [String] = [], entityIDs: [String] = [],
        levels: [String: TimeInterval] = [:],
        spheres: [String: TimeInterval] = [:]
    ) {
        self.key = key
        self.duration = duration
        self.categories = categories
        self.levels = levels
        self.spheres = spheres
        self.interactions = interactions
        self.entityNames = entityNames
        self.entityIDs = entityIDs
    }
}

struct AttentionDimension: Codable, Equatable, Identifiable, Sendable {
    static let title = "title"
    static let url = "url"
    static let entity = "entity"
    static let category = "category"

    var id: String { key }
    var key: String
    var rows: [AttentionBreakdownRow]
    var total: TimeInterval

    init(key: String, rows: [AttentionBreakdownRow], total: TimeInterval) {
        self.key = key
        self.rows = rows
        self.total = total
    }

    var title: String {
        switch key {
        case Self.title: "Page and window title"
        case Self.url: "URL"
        case Self.entity: "App and site"
        case Self.category: "Category"
        case "profile": "Browser profile"
        default: AttentionTag.title(key)
        }
    }
}

struct AttentionAgentTotal: Codable, Equatable, Identifiable, Sendable {
    var id: String { key }
    var key: String
    var working: TimeInterval
    var blocked: TimeInterval
    var sessions: Int
    var attended: TimeInterval

    init(
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

struct AttentionAgentSession: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var title: String
    var machine: String
    var kind: String
    var project: String?
    var working: TimeInterval
    var blocked: TimeInterval
    var lastSeen: Date

    init(
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

struct AttentionConcurrencyPoint: Codable, Equatable, Identifiable, Sendable {
    var id: Date { start }
    var start: Date
    var working: Double
    var attention: TimeInterval

    init(start: Date, working: Double, attention: TimeInterval) {
        self.start = start
        self.working = working
        self.attention = attention
    }
}

struct AttentionAgentSummary: Codable, Equatable, Sendable {
    var working: TimeInterval
    var blocked: TimeInterval
    var attended: TimeInterval
    var peakConcurrent: Int
    var machines: [AttentionAgentTotal]
    var kinds: [AttentionAgentTotal]
    var projects: [AttentionAgentTotal]
    var sessions: [AttentionAgentSession]
    var concurrency: [AttentionConcurrencyPoint]

    init(
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

    var isEmpty: Bool { working == 0 && blocked == 0 && sessions.isEmpty }
}

enum AttentionLevels {
    static func duration(
        _ levels: [String: TimeInterval], _ level: AttentionProductivity
    ) -> TimeInterval {
        levels[level.key] ?? 0
    }

    static func productive(_ levels: [String: TimeInterval]) -> TimeInterval {
        duration(levels, .productive) + duration(levels, .veryProductive)
    }

    static func distracting(_ levels: [String: TimeInterval]) -> TimeInterval {
        duration(levels, .distracting) + duration(levels, .veryDistracting)
    }

    static func pulse(_ levels: [String: TimeInterval], unclassified: TimeInterval)
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

struct AttentionTotals: Codable, Equatable, Sendable {
    var active: TimeInterval
    var levels: [String: TimeInterval]
    var spheres: [String: TimeInterval]
    var unclassified: TimeInterval
    var deepWork: TimeInterval
    var contextSwitches: Int
    var agentWorking: TimeInterval

    init(
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

    var productive: TimeInterval { AttentionLevels.productive(levels) }
    var distracting: TimeInterval { AttentionLevels.distracting(levels) }
    var pulse: Double? { AttentionLevels.pulse(levels, unclassified: unclassified) }
}

struct AttentionSummary: Codable, Equatable, Sendable {
    var from: Date
    var to: Date
    var activeDuration: TimeInterval
    var idleDuration: TimeInterval
    var levels: [String: TimeInterval]
    var spheres: [String: TimeInterval]
    var unclassifiedDuration: TimeInterval
    var contextSwitches: Int
    var medianStretch: TimeInterval
    var longestStretch: TimeInterval
    var entities: [AttentionEntity]
    var categories: [AttentionCategoryTotal]
    var music: [AttentionMusicSummary]
    var days: [AttentionDayTotal]
    var hours: [AttentionHourCell]
    var spans: [AttentionSpan]
    var focusBlocks: [AttentionFocusBlock]
    var transitions: [AttentionTransition]
    var dimensions: [AttentionDimension]
    var agents: AttentionAgentSummary
    var signals: AttentionSignals
    var previous: AttentionTotals?

    init(
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

    func screenTime(excludingIdle: Bool) -> TimeInterval {
        activeDuration + (excludingIdle ? 0 : idleDuration)
    }

    func duration(_ level: AttentionProductivity) -> TimeInterval {
        AttentionLevels.duration(levels, level)
    }

    func duration(_ sphere: AttentionSphere) -> TimeInterval {
        spheres[sphere.rawValue] ?? 0
    }

    var productiveDuration: TimeInterval { AttentionLevels.productive(levels) }
    var distractingDuration: TimeInterval { AttentionLevels.distracting(levels) }
    var pulse: Double? { AttentionLevels.pulse(levels, unclassified: unclassifiedDuration) }
    var deepWorkDuration: TimeInterval { focusBlocks.reduce(0) { $0 + $1.duration } }

    var totals: AttentionTotals {
        AttentionTotals(
            active: activeDuration, levels: levels, spheres: spheres,
            unclassified: unclassifiedDuration, deepWork: deepWorkDuration,
            contextSwitches: contextSwitches, agentWorking: agents.working)
    }

    func dimension(_ key: String) -> AttentionDimension? {
        dimensions.first { $0.key == key }
    }
}
