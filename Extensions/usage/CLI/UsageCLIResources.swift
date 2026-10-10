import Foundation

@MainActor final class UsageCLIResources {
    let controller: UsageWorkerController
    let hookOwner: UsageCLIHookOwner?
    let forgetMachine: @MainActor (UUID) async throws -> Void

    init(
        controller: UsageWorkerController, hookOwner: UsageCLIHookOwner? = nil,
        forgetMachine: @escaping @MainActor (UUID) async throws -> Void = {
            try UsageMachinesPeer.forget(machineID: $0)
        }
    ) {
        self.controller = controller
        self.hookOwner = hookOwner
        self.forgetMachine = forgetMachine
    }
}
