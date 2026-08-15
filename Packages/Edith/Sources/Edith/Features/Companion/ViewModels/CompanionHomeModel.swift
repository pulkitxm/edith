import EdithKit
import Observation

@MainActor
@Observable
final class CompanionHomeModel: CompanionRefreshable {
    private(set) var checks: [CompanionCheck] = []
    private(set) var status: CompanionStatus?
    private(set) var error: String?
    private(set) var generation = 0
    private var reachable = false

    var client: CompanionClient {
        CompanionClient(baseURL: CompanionClient.endpoint(override: nil))
    }

    var healthy: Bool { !checks.isEmpty && checks.allSatisfy(\.ok) }

    func refresh() async {
        do {
            let client = client
            checks = try await client.health().checks
            status = try await client.status()
            error = nil
            if !reachable {
                reachable = true
                generation += 1
            }
        } catch {
            self.error = error.localizedDescription
            reachable = false
        }
    }
}
