import EdithExtensionSupport
import Foundation

@MainActor final class UsageCLIResources {
    let defaults: UserDefaults
    let controller: UsageWorkerController
    let hookOwner: UsageCLIHookOwner?
    let forgetMachine: @MainActor (UUID) async throws -> Void

    init(
        controller: UsageWorkerController, defaults: UserDefaults = SharedDefaults.store,
        hookOwner: UsageCLIHookOwner? = nil,
        forgetMachine: @escaping @MainActor (UUID) async throws -> Void = {
            try UsageMachinesPeer.forget(machineID: $0)
        }
    ) {
        self.defaults = defaults
        self.controller = controller
        self.hookOwner = hookOwner
        self.forgetMachine = forgetMachine
    }
}
