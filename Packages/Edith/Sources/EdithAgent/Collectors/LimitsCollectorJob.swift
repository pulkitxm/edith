import EdithKit
import Foundation

public final class LimitsCollectorJob: @unchecked Sendable {
    private let refresh: @Sendable () async -> LimitsTopicSnapshot

    public init(
        refresh: @escaping @Sendable () async -> LimitsTopicSnapshot = {
            await LimitsCollector.refresh()
        }
    ) {
        self.refresh = refresh
    }

    public func run() async throws -> Data? {
        let snapshot = await refresh()
        return try AgentPayload.encode(snapshot)
    }
}
