import Foundation

public enum AttentionOperation {
    public static let record = "attention.record"
    public static let range = "attention.range"
    public static let importLegacy = "attention.import"
    public static let hasEvents = "attention.hasEvents"
    public static let summary = "attention.summary"
    public static let backup = "attention.backup"
    public static let restore = "attention.restore"
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

    public init(from: Date, to: Date, settings: AttentionSettings? = nil) {
        self.from = from
        self.to = to
        self.settings = settings
    }
}

public struct AttentionPageSnapshot: Codable, Sendable {
    public let settings: AttentionSettings
    public let summary: AttentionSummary
    public let events: [AttentionEvent]
    public let focusSessions: [AttentionFocusSession]
    public let activeFocus: AttentionFocusSession?
    public let hasStoredEvents: Bool

    public init(request: AttentionSummaryRequest, repository: AttentionRepository) {
        self.init(
            request: request, repository: repository,
            all: repository.events(from: request.from, to: request.to),
            hasStoredEvents: repository.hasEvents())
    }

    public init(
        request: AttentionSummaryRequest, repository: AttentionRepository,
        all: [AttentionEvent], hasStoredEvents: Bool
    ) {
        settings = request.settings ?? repository.loadSettings()
        summary = AttentionAnalyzer().summary(
            events: all, settings: settings, from: request.from, to: request.to)
        events = Array(all.reversed().prefix(500))
        focusSessions = Array(
            repository.focusSessions(from: request.from, to: request.to).reversed())
        activeFocus = repository.activeFocus()
        self.hasStoredEvents = hasStoredEvents
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

    public static func backup(client: AgentClient = .shared) async throws {
        _ = try await client.performInternalAsync(
            AttentionOperation.backup, payload: Data(), timeout: 120)
    }

    public static func restore(client: AgentClient = .shared) async throws {
        _ = try await client.performInternalAsync(
            AttentionOperation.restore, payload: Data(), timeout: 120)
    }
}
