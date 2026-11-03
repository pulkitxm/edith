import EdithExtensionSupport
import Foundation
import WorkerFixtureSupport

@testable import CompanionExtension

@MainActor
struct CompanionTestRuntime {
    let runtime: ExtensionServiceRuntime
    let service: CompanionService

    init(
        settingsChanged: @escaping @MainActor () -> Void = {},
        fixtureAdmission: @escaping (NSDictionary) throws -> WorkerFixtureAdmission?
    ) {
        var created: CompanionService?
        runtime = ExtensionServiceRuntime(id: "companion", role: "app", bundle: .main) {
            let service = CompanionService(
                runtime: $0, settingsChanged: settingsChanged, fixtureAdmission: fixtureAdmission)
            created = service
            return service
        }
        service = created!
    }
}
