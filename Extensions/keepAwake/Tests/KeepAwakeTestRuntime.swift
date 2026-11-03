import EdithExtensionSupport
import Foundation
import WorkerFixtureSupport

@testable import KeepAwakeExtension

@MainActor
struct KeepAwakeTestRuntime {
    let runtime: ExtensionServiceRuntime
    let service: KeepAwakeService

    init(
        suite: String,
        admitFixture: @escaping (NSDictionary) throws -> WorkerFixtureAdmission?,
        makeDefaults: @escaping (String) -> UserDefaults? = { UserDefaults(suiteName: $0) },
        makeProductionStore: @escaping @MainActor (UserDefaults) -> KeepAwakeStore = {
            KeepAwakeStore(defaults: $0)
        }
    ) {
        let values = ["EDITH_SHARED_DEFAULTS_SUITE": suite]
        ExtensionScope.register(
            ExtensionScope(
                environment: { values },
                value: { values[$0] },
                defaults: { .standard },
                dataRoot: { ExtensionScope.temporaryDataRoot() }),
            image: #dsohandle)
        var created: KeepAwakeService?
        runtime = ExtensionServiceRuntime(id: "keepAwake", role: "helper", bundle: .main) {
            let service = KeepAwakeService(
                runtime: $0, admitFixture: admitFixture, makeDefaults: makeDefaults,
                makeProductionStore: makeProductionStore)
            created = service
            return service
        }
        service = created!
    }
}
