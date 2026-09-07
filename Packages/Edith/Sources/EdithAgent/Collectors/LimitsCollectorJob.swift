import EdithKit
import Foundation

public final class LimitsCollectorJob: @unchecked Sendable {
    private let refresh: @Sendable () async -> LimitsTopicSnapshot
    private let notify: @Sendable (LimitsTopicSnapshot) async throws -> Void

    public init(
        notify: @escaping @Sendable (LimitsTopicSnapshot) async throws -> Void = {
            try await AgentNotificationService.collectLimits($0)
        },
        refresh: @escaping @Sendable () async -> LimitsTopicSnapshot = {
            await LimitsCollector.refresh()
        }
    ) {
        self.refresh = refresh
        self.notify = notify
    }

    public func run() async throws -> Data? {
        let snapshot = await refresh()
        try await notify(snapshot)
        return try AgentPayload.encode(snapshot)
    }
}
