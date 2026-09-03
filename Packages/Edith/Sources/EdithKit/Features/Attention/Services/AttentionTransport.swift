import Foundation

public enum AttentionOperation {
    public static let record = "attention.record"
    public static let range = "attention.range"
    public static let importLegacy = "attention.import"
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
}
