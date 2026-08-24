import Foundation
import os

public enum PerformanceArea: String, CaseIterable, Codable, Sendable {
    case startup
    case input
    case repository
    case git
    case github
    case extensionDiscovery
    case uiRendering
    case cache
    case backgroundWorker
    case generation
    case memory
    case mainThread
    case largeRepository
    case slowNetwork
}

public struct PerformanceSpan {
    public let area: PerformanceArea
    public let name: String
    public let beganOnMainThread: Bool
    fileprivate let signpostID: OSSignpostID
}

public enum PerformanceTrace {
    private static let log = OSLog(
        subsystem: "com.pulkit.edith", category: "performance")

    @discardableResult
    public static func begin(_ area: PerformanceArea, _ name: String) -> PerformanceSpan {
        let id = OSSignpostID(log: log)
        let main = Thread.isMainThread
        os_signpost(
            .begin, log: log, name: "Operation", signpostID: id,
            "%{public}@ %{public}@ main=%{public}d", area.rawValue, name, main ? 1 : 0)
        return PerformanceSpan(
            area: area, name: name, beganOnMainThread: main, signpostID: id)
    }

    public static func end(_ span: PerformanceSpan) {
        os_signpost(
            .end, log: log, name: "Operation", signpostID: span.signpostID,
            "%{public}@ %{public}@ main=%{public}d", span.area.rawValue, span.name,
            Thread.isMainThread ? 1 : 0)
    }

    public static func event(_ area: PerformanceArea, _ name: String) {
        os_signpost(
            .event, log: log, name: "Event", "%{public}@ %{public}@ main=%{public}d",
            area.rawValue, name, Thread.isMainThread ? 1 : 0)
    }

    public static func measure<Result>(
        _ area: PerformanceArea, _ name: String, operation: () throws -> Result
    ) rethrows -> Result {
        let span = begin(area, name)
        defer { end(span) }
        return try operation()
    }

    public static func measure<Result>(
        _ area: PerformanceArea, _ name: String, operation: () async throws -> Result
    ) async rethrows -> Result {
        let span = begin(area, name)
        defer { end(span) }
        return try await operation()
    }
}
