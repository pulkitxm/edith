import EdithKit
import Observation

@MainActor
@Observable
final class CompanionHomeModel: CompanionRefreshable {
    private(set) var checks: [CompanionCheck] = []
    private(set) var status: CompanionStatus?
    private(set) var error: String?

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
        } catch {
            self.error = error.localizedDescription
        }
    }
}
