import Foundation

public struct VirtualCameraRelay: Sendable {
    public enum Feed: String, Equatable, Sendable {
        case offline
        case starting
        case live
        case stalled
    }

    public private(set) var consumers: [UUID: String]
    public private(set) var sinkRunning: Bool
    public private(set) var lastFrameAt: UInt64?
    public let stallAfter: UInt64

    public init(stallAfterNanoseconds: UInt64 = 750_000_000) {
        consumers = [:]
        sinkRunning = false
        lastFrameAt = nil
        stallAfter = stallAfterNanoseconds
    }

    public var hasConsumers: Bool { !consumers.isEmpty }

    public var clientNames: [String] {
        Array(Set(consumers.values)).sorted()
    }

    @discardableResult
    public mutating func setConsumers(_ clients: [(id: UUID, signingID: String?)]) -> Bool {
        var next: [UUID: String] = [:]
        for client in clients {
            next[client.id] = Self.displayName(for: client.signingID)
        }
        guard next != consumers else { return false }
        consumers = next
        return true
    }

    public mutating func sinkStarted() {
        sinkRunning = true
        lastFrameAt = nil
    }

    public mutating func sinkStopped() {
        sinkRunning = false
        lastFrameAt = nil
    }

    public mutating func frameArrived(at now: UInt64) {
        sinkRunning = true
        lastFrameAt = now
    }

    public func feed(at now: UInt64) -> Feed {
        guard sinkRunning else { return .offline }
        guard let lastFrameAt else { return .starting }
        return now &- lastFrameAt > stallAfter ? .stalled : .live
    }

    public func needsPlaceholder(at now: UInt64) -> Bool {
        hasConsumers && feed(at: now) != .live
    }

    public func isReceivingFrames(at now: UInt64) -> Bool {
        feed(at: now) == .live
    }

    public static func displayName(for signingID: String?) -> String {
        guard let signingID, !signingID.isEmpty else { return "unknown" }
        return signingID
    }
}
