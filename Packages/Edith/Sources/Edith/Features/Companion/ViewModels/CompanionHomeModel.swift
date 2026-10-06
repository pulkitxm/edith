import EdithKit
import Observation

@MainActor
@Observable
final class CompanionHomeModel: CompanionRefreshable {
    private(set) var checks: [CompanionCheck] = []
    private(set) var status: CompanionStatus?
    let loading = ContentLoad()
    var error: String? { loading.errorMessage }
    private(set) var generation = 0
    private(set) var reachable = false
    var hasAttemptedRefresh: Bool { loading.state != .loading && loading.state != .cancelled }

    var client: CompanionClient {
        CompanionClient(baseURL: CompanionClient.endpoint(override: nil))
    }

    var blocking: [CompanionCheck] {
        checks.filter { !$0.ok && $0.severityKind == .blocker }
    }

    var failing: [CompanionCheck] { checks.filter { !$0.ok } }

    var healthy: Bool { reachable && blocking.isEmpty }

    var state: CompanionHealthState {
        guard reachable else { return .unreachable }
        if !blocking.isEmpty { return .blocked(blocking.count) }
        if !failing.isEmpty { return .degraded(failing.count) }
        return .ready
    }

    func refresh() async {
        let client = client
        await loading.perform(operation: {
            async let liveness = client.health(timeout: 5)
            async let snapshot = client.status()
            return try await (liveness.checks, snapshot)
        }) { result in
            checks = result.0
            status = result.1
            if !reachable {
                reachable = true
                generation += 1
            }
        }
        if loading.errorMessage != nil {
            reachable = false
        }
    }
}

enum CompanionHealthState: Equatable {
    case unreachable
    case blocked(Int)
    case degraded(Int)
    case ready

    var label: String {
        switch self {
        case .unreachable: "not running"
        case let .blocked(count): count == 1 ? "1 check failing" : "\(count) checks failing"
        case let .degraded(count):
            count == 1 ? "ready, 1 optional off" : "ready, \(count) optional off"
        case .ready: "ready"
        }
    }
}
