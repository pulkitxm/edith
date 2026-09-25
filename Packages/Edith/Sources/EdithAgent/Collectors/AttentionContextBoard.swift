import EdithKit
import Foundation

final class AttentionContextBoard: @unchecked Sendable {
    static let shared = AttentionContextBoard()
    static let freshness: TimeInterval = 90

    private let lock = NSLock()
    private var current: AttentionAppContext?
    private var updatedAt = Date.distantPast

    func update(_ context: AttentionAppContext, now: Date = Date()) {
        lock.withLock {
            current = context
            updatedAt = now
        }
    }

    func context(for bundleID: String?, now: Date = Date()) -> AttentionAppContext? {
        lock.withLock {
            guard let current, let bundleID, current.bundleID == bundleID,
                now.timeIntervalSince(updatedAt) <= Self.freshness
            else { return nil }
            return current
        }
    }
}
