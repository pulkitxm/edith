import EdithKit
import Foundation

public struct UsageRefreshDriver: Sendable {
    public typealias Sink = @Sendable (UsageRefreshEvent) -> Void

    public var isRunning: @Sendable () -> Bool
    public var start: @Sendable (@escaping Sink) async throws -> UsageRefreshResult
    public var attach: @Sendable (@escaping Sink) async throws -> UsageRefreshResult

    public init(
        isRunning: @escaping @Sendable () -> Bool,
        start: @escaping @Sendable (@escaping Sink) async throws -> UsageRefreshResult,
        attach: @escaping @Sendable (@escaping Sink) async throws -> UsageRefreshResult
    ) {
        self.isRunning = isRunning
        self.start = start
        self.attach = attach
    }

    public static let live = UsageRefreshDriver(
        isRunning: { UsageRefreshRunner.isRunning },
        start: { try await UsageRefreshRunner.run(onEvent: $0) },
        attach: { try await UsageRefreshFollower.follow(onEvent: $0) })

    public static func scripted(
        events: [UsageRefreshEvent], busy: Bool = false, failure: UsageRefreshFailure? = nil
    ) -> UsageRefreshDriver {
        let replay: @Sendable (@escaping Sink) async throws -> UsageRefreshResult = { sink in
            if let failure { throw failure }
            for event in events { sink(event) }
            let seconds = events.compactMap { event -> Double? in
                guard case let .finished(value) = event else { return nil }
                return value
            }.last
            return UsageRefreshResult(
                events: events, seconds: seconds ?? 0, startedAt: Date())
        }
        return UsageRefreshDriver(
            isRunning: { busy },
            start: { sink in
                if busy { throw UsageRefreshFailure.busy }
                return try await replay(sink)
            },
            attach: replay)
    }
}
