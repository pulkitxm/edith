import Foundation

@MainActor public enum HostCoreAgentCLIFactory {
    public static func make(
        local: HostCoreAgentCLIBackend, invoke: @escaping HostCLIProviderRegistry.Invoke
    ) -> HostCoreAgentCLI {
        let hooks = HostCoreOwnerHooks(invoke: invoke)
        return HostCoreAgentCLI(
            backend: .init(
                ownedJobs: local.ownedJobs, command: local.command,
                status: {
                    var status = try await local.status()
                    status.subscribers += try await hooks.jobs().reduce(0) { $0 + $1.subscribers }
                    return status
                },
                jobs: {
                    let jobs = try await local.jobs() + hooks.jobs()
                    guard Set(jobs.map(\.id)).count == jobs.count else {
                        throw HostCoreCommandFailure(
                            "Conflicting background job owners.",
                            hint: "Update the conflicting extensions.")
                    }
                    return jobs
                }, restart: local.restart,
                logs: { last in try await local.logs(last) + hooks.logs(last: last) },
                events: {
                    let events = try await local.events() + hooks.events()
                    guard Set(events.map(\.id)).count == events.count else {
                        throw HostCoreCommandFailure(
                            "Conflicting background event owners.",
                            hint: "Update the conflicting extensions.")
                    }
                    return Array(
                        events.sorted {
                            $0.date == $1.date
                                ? $0.id.uuidString < $1.id.uuidString : $0.date < $1.date
                        }.suffix(500))
                },
                run: { job in
                    if local.ownedJobs().contains(job) {
                        try await local.run(job)
                    } else {
                        try await hooks.control(job: job, cancel: false)
                    }
                },
                cancel: { job in
                    if local.ownedJobs().contains(job) {
                        try await local.cancel(job)
                    } else {
                        try await hooks.control(job: job, cancel: true)
                    }
                }))
    }
}
