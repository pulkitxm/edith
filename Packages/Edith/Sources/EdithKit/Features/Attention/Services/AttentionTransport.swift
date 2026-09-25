import Foundation

public enum AttentionOperation {
    public static let record = "attention.record"
    public static let range = "attention.range"
    public static let importLegacy = "attention.import"
    public static let hasEvents = "attention.hasEvents"
    public static let summary = "attention.summary"
    public static let backup = "attention.backup"
    public static let restore = "attention.restore"
    public static let context = "attention.context"
    public static let categorize = "attention.categorize"
}

public struct AttentionCategorizeReport: Codable, Equatable, Sendable {
    public var entities: Int
    public var titles: Int
    public var available: Bool

    public init(entities: Int = 0, titles: Int = 0, available: Bool) {
        self.entities = entities
        self.titles = titles
        self.available = available
    }
}

public struct AttentionBatch: Codable, Equatable, Sendable {
    public let events: [AttentionEvent]
    public let pulseTime: TimeInterval

    public init(events: [AttentionEvent], pulseTime: TimeInterval = 30) {
        self.events = events
        self.pulseTime = pulseTime
    }
}

public struct AttentionRangeRequest: Codable, Equatable, Sendable {
    public let from: Date
    public let to: Date

    public init(from: Date, to: Date) {
        self.from = from
        self.to = to
    }
}

public struct AttentionRangeResponse: Codable, Equatable, Sendable {
    public let events: [AttentionEvent]

    public init(events: [AttentionEvent]) {
        self.events = events
    }
}

public enum AttentionRetention {
    public static let days = 365

    public static func cutoff(now: Date = Date()) -> Date {
        now.addingTimeInterval(-Double(days) * 24 * 60 * 60)
    }

    public static func isExpired(_ event: AttentionEvent, now: Date = Date()) -> Bool {
        event.startedAt < cutoff(now: now)
    }
}

public enum AttentionMerge {
    public static func fold(
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

public protocol AttentionEventSink: Sendable {
    func record(_ batch: AttentionBatch) throws
    func events(from: Date, to: Date) throws -> [AttentionEvent]
    func hasEvents() throws -> Bool
}

public struct AgentAttentionSink: AttentionEventSink {
    private let client: AgentClient

    public init(client: AgentClient = .shared) {
        self.client = client
    }

    public func record(_ batch: AttentionBatch) throws {
        _ = try client.performInternal(
            AttentionOperation.record, payload: AgentPayload.encode(batch))
    }

    public func events(from: Date, to: Date) throws -> [AttentionEvent] {
        let payload = try AgentPayload.encode(AttentionRangeRequest(from: from, to: to))
        let data = try client.performInternal(AttentionOperation.range, payload: payload)
        return try AgentPayload.decode(AttentionRangeResponse.self, from: data).events
    }

    public func hasEvents() throws -> Bool {
        let data = try client.performInternal(AttentionOperation.hasEvents, payload: Data())
        return try AgentPayload.decode(Bool.self, from: data)
    }
}

public struct AttentionSummaryRequest: Codable, Sendable {
    public let from: Date
    public let to: Date
    public let settings: AttentionSettings?
    public let comparePeriod: TimeInterval?
    public let window: AttentionTimeWindow
    public let parts: Set<AttentionSummaryPart>

    public init(
        from: Date, to: Date, settings: AttentionSettings? = nil,
        comparePeriod: TimeInterval? = nil, window: AttentionTimeWindow = .all,
        parts: Set<AttentionSummaryPart> = Set(AttentionSummaryPart.allCases)
    ) {
        self.from = from
        self.to = to
        self.settings = settings
        self.comparePeriod = comparePeriod
        self.window = window
        self.parts = parts
    }

    public var previousInterval: DateInterval? {
        guard let comparePeriod, comparePeriod > 0 else { return nil }
        return DateInterval(
            start: from.addingTimeInterval(-comparePeriod),
            end: max(from.addingTimeInterval(-comparePeriod), to.addingTimeInterval(-comparePeriod))
        )
    }
}

public struct AttentionPageSnapshot: Codable, Sendable {
    public var settings: AttentionSettings
    public var summary: AttentionSummary
    public var focusSessions: [AttentionFocusSession]
    public var activeFocus: AttentionFocusSession?
    public var hasStoredEvents: Bool
    public var classifications: AttentionClassifications

    public init(request: AttentionSummaryRequest, repository: AttentionRepository) {
        self.init(
            request: request, repository: repository,
            all: repository.events(from: request.from, to: request.to),
            previous: request.previousInterval.map {
                repository.events(from: $0.start, to: $0.end)
            },
            hasStoredEvents: repository.hasEvents())
    }

    public init(
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

    public func trimmed(to parts: Set<AttentionSummaryPart>) -> AttentionPageSnapshot {
        var copy = self
        copy.summary = summary.trimmed(to: parts)
        return copy
    }
}

public enum AttentionBackgroundClient {
    public static func summary(
        _ request: AttentionSummaryRequest, client: AgentClient = .shared
    ) async throws -> AttentionPageSnapshot {
        let data = try await client.performInternalAsync(
            AttentionOperation.summary, payload: AgentPayload.encode(request), timeout: 30)
        return try AgentPayload.decode(AttentionPageSnapshot.self, from: data)
    }

    public static func publish(_ context: AttentionAppContext, client: AgentClient = .shared)
        async throws
    {
        _ = try await client.performInternalAsync(
            AttentionOperation.context, payload: AgentPayload.encode(context), timeout: 5)
    }

    public static func categorize(client: AgentClient = .shared) async throws
        -> AttentionCategorizeReport
    {
        let data = try await client.performInternalAsync(
            AttentionOperation.categorize, payload: Data(), timeout: 120)
        return try AgentPayload.decode(AttentionCategorizeReport.self, from: data)
    }

    public static func backup(client: AgentClient = .shared) async throws {
        _ = try await client.performInternalAsync(
            AttentionOperation.backup, payload: Data(), timeout: 120)
    }

    public static func restore(client: AgentClient = .shared) async throws {
        _ = try await client.performInternalAsync(
            AttentionOperation.restore, payload: Data(), timeout: 120)
    }
}
