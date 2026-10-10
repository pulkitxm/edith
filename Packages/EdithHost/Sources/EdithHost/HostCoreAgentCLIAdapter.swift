import EdithHostCore
import Foundation

@MainActor enum HostCoreAgentCLIAdapter {
    static func backend(core: @escaping @MainActor () -> HostCoreServices?)
        -> HostCoreAgentCLIBackend
    {
        func service() throws -> HostCoreServices {
            guard let service = core(), service.online else {
                throw HostCoreCommandFailure(
                    "background agent",
                    hint:
                        "The owned same-executable core process is not running. Restart this Edith app installation."
                )
            }
            return service
        }
        return .init(
            ownedJobs: { core()?.cliOwnedJobIDs ?? [] },
            status: { try await service().cliStatus() }, jobs: { try await service().cliJobs() },
            restart: { try await service().cliRestart() },
            logs: { try await service().cliLogs(last: $0) },
            events: { try await service().cliEvents() }, run: { try service().cliRun(job: $0) },
            cancel: { try service().cliCancel(job: $0) })
    }
}
