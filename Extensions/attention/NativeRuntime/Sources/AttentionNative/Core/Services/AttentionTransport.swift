@_implementationOnly import EdithExtensionSupport_attention_native
@_implementationOnly import EdithExtensionUI_attention_native
import Foundation

enum AttentionOperation {
    static let record = "attention.record"
    static let range = "attention.range"
    static let importLegacy = "attention.import"
    static let hasEvents = "attention.hasEvents"
    static let summary = "attention.summary"
    static let backup = "attention.backup"
    static let restore = "attention.restore"
    static let context = "attention.context"
    static let categorize = "attention.categorize"
}

struct AttentionCategorizeReport: Codable, Equatable, Sendable {
    var entities: Int
    var titles: Int
    var available: Bool

    init(entities: Int = 0, titles: Int = 0, available: Bool) {
        self.entities = entities
        self.titles = titles
        self.available = available
    }
}

struct AttentionBatch: Codable, Equatable, Sendable {
    let events: [AttentionEvent]
    let pulseTime: TimeInterval

    init(events: [AttentionEvent], pulseTime: TimeInterval = 30) {
        self.events = events
        self.pulseTime = pulseTime
    }
}

struct AttentionRangeRequest: Codable, Equatable, Sendable {
    let from: Date
    let to: Date

    init(from: Date, to: Date) {
        self.from = from
        self.to = to
    }
}

struct AttentionRangeResponse: Codable, Equatable, Sendable {
    let events: [AttentionEvent]

    init(events: [AttentionEvent]) {
        self.events = events
    }
}

enum AttentionRetention {
    static let days = 365

    static func cutoff(now: Date = Date()) -> Date {
        now.addingTimeInterval(-Double(days) * 24 * 60 * 60)
    }

    static func isExpired(_ event: AttentionEvent, now: Date = Date()) -> Bool {
        event.startedAt < cutoff(now: now)
    }
}

enum AttentionMerge {
    static func fold(
        _ existing: [AttentionEvent], with incoming: AttentionEvent, pulseTime: TimeInterval
    ) -> [AttentionEvent] {
        guard let last = existing.last, last.canMerge(with: incoming, pulseTime: pulseTime) else {
            return existing + [incoming]
        }
        var merged = existing
        merged[merged.count - 1] = last.merged(with: incoming)
        return merged
    }
}

protocol AttentionEventSink: Sendable {
    func record(_ batch: AttentionBatch) throws
    func events(from: Date, to: Date) throws -> [AttentionEvent]
    func hasEvents() throws -> Bool
}

struct AttentionSummaryRequest: Codable, Sendable {
    let from: Date
    let to: Date
    let settings: AttentionSettings?
    let comparePeriod: TimeInterval?
    let window: AttentionTimeWindow
    let parts: Set<AttentionSummaryPart>
    let allTime: Bool

    init(
        from: Date, to: Date, settings: AttentionSettings? = nil,
        comparePeriod: TimeInterval? = nil, window: AttentionTimeWindow = .all,
        parts: Set<AttentionSummaryPart> = Set(AttentionSummaryPart.allCases), allTime: Bool = false
    ) {
        self.from = from
        self.to = to
        self.settings = settings
        self.comparePeriod = comparePeriod
        self.window = window
        self.parts = parts
        self.allTime = allTime
    }

    func coveringAllTime(since first: Date?, calendar: Calendar = .current)
        -> AttentionSummaryRequest
    {
        guard allTime else { return self }
        return AttentionSummaryRequest(
            from: min(calendar.startOfDay(for: first ?? to), to), to: to, settings: settings,
            window: window, parts: parts, allTime: true)
    }

    var previousInterval: DateInterval? {
        guard let comparePeriod, comparePeriod > 0 else { return nil }
        return DateInterval(
            start: from.addingTimeInterval(-comparePeriod),
            end: max(from.addingTimeInterval(-comparePeriod), to.addingTimeInterval(-comparePeriod))
        )
    }
}

struct AttentionPageSnapshot: Codable, Sendable {
    var settings: AttentionSettings
    var summary: AttentionSummary
    var focusSessions: [AttentionFocusSession]
    var activeFocus: AttentionFocusSession?
    var hasStoredEvents: Bool
    var classifications: AttentionClassifications

    init(request: AttentionSummaryRequest, repository: AttentionRepository) {
        let all = repository.events(
            from: request.allTime ? .distantPast : request.from, to: request.to)
        let request = request.coveringAllTime(since: all.first?.startedAt)
        self.init(
            request: request, repository: repository,
            all: all,
            previous: request.previousInterval.map {
                repository.events(from: $0.start, to: $0.end)
            },
            hasStoredEvents: repository.hasEvents())
    }

    init(
        request: AttentionSummaryRequest, repository: AttentionRepository,
        all: [AttentionEvent], previous: [AttentionEvent]?, hasStoredEvents: Bool,
        previousTotals: AttentionTotals? = nil, calendar: Calendar = .current
    ) {
        settings = request.settings ?? repository.loadSettings()
        classifications = repository.loadClassifications()
        let analyzer = AttentionAnalyzer(calendar: calendar)
        var summary = analyzer.summary(
            events: request.window.apply(all, calendar: calendar), settings: settings,
            classifications: classifications, from: request.from, to: request.to)
        if !request.window.allDays {
            summary.days.removeAll {
                !request.window.allows(weekday: calendar.component(.weekday, from: $0.day))
            }
        }
        if let previousTotals {
            summary.previous = previousTotals
        } else if let previous, let interval = request.previousInterval {
            summary.previous =
                analyzer.summary(
                    events: request.window.apply(previous, calendar: calendar),
                    settings: settings, classifications: classifications,
                    from: interval.start, to: interval.end, detailed: false
                ).totals
        }
        self.summary = summary
        focusSessions = Array(
            repository.focusSessions(from: request.from, to: request.to).reversed())
        activeFocus = repository.activeFocus()
        self.hasStoredEvents = hasStoredEvents
    }

    func trimmed(to parts: Set<AttentionSummaryPart>) -> AttentionPageSnapshot {
        var copy = self
        copy.summary = summary.trimmed(to: parts)
        return copy
    }
}

enum AttentionBackgroundClient {
    static func summary(_ request: AttentionSummaryRequest) async throws -> AttentionPageSnapshot {
        try AttentionPayload.decode(
            AttentionPageSnapshot.self,
            from: await AttentionPeer.invoke(
                AttentionOperation.summary, payload: AttentionPayload.encode(request)))
    }
    static func publish(_ context: AttentionAppContext) async throws {
        _ = try await AttentionPeer.invoke(
            AttentionOperation.context, payload: AttentionPayload.encode(context))
    }
    static func categorize() async throws -> AttentionCategorizeReport {
        try AttentionPayload.decode(
            AttentionCategorizeReport.self,
            from: await AttentionPeer.invoke(AttentionOperation.categorize, timeout: 120))
    }
    static func backup() async throws {
        _ = try await AttentionPeer.invoke(AttentionOperation.backup, timeout: 120)
    }
    static func restore() async throws {
        _ = try await AttentionPeer.invoke(AttentionOperation.restore, timeout: 120)
    }
}
