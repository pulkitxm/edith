import EdithExtensionSupport
import EdithHostCore
import Foundation

@MainActor enum HostBackgroundSource {
    private struct CoreProjection: Decodable {
        struct Agent: Decodable {
            let jobs: [HostBackgroundJob]
            let events: [HostBackgroundEvent]
        }
        let agent: Agent?
    }
    private struct Hooks: Decodable {
        struct Catalog: Decodable {
            struct Agent: Decodable {
                let jobs: String
                let run: String?
                let cancel: String?
                let events: String?
            }
            let version: Int
            let owner: String
            let agent: Agent?
        }
        let coreOwner: Catalog?
    }
    private struct Jobs: Decodable { let owner: String; let jobs: [HostBackgroundJob] }
    private struct Events: Decodable { let owner: String; let events: [HostBackgroundEvent] }
    private struct Envelope: Encodable {
        let arguments: [String]
        let input = Data()
        let workingDirectory = "/"
    }

    static func live(_ services: HostCoreServices) -> HostBackgroundEnvironment {
        let gateway = HostCLIGateway(marketplace: services.marketplace)
        return HostBackgroundEnvironment(
            identity: { identity(services) },
            read: {
                guard let snapshot = services.snapshot, services.online else {
                    throw HostCLIError.unavailable
                }
                let core = try JSONDecoder().decode(
                    CoreProjection.self, from: JSONEncoder().encode(snapshot))
                guard let agent = core.agent else {
                    return .init(
                        jobs: [], events: [],
                        unavailable:
                            "This background service does not expose its job inventory or event timeline. Update Edith to use these controls."
                    )
                }
                var jobs = agent.jobs
                var events = agent.events
                var missing: [String] = []
                let states = try await HostCLIProviderRegistry.states { request in
                    try await gateway.execute(request)
                }
                for state in states
                where state.available && HostCLIProviderCatalog.prefixes[state.id] != nil {
                    let catalog: Hooks
                    do {
                        catalog = try await call(
                            Hooks.self, gateway: gateway, state: state,
                            operation: state.id + ".cli.catalog")
                    } catch is CancellationError { throw CancellationError() } catch {
                        missing.append(state.id + ": background capabilities are unavailable.")
                        continue
                    }
                    guard let owner = catalog.coreOwner else {
                        if [
                            "herdr", "usage", "machines", "appMaintenance", "cleaner", "downloads",
                            "attention", "companion", "codeStats",
                        ].contains(state.id) {
                            missing.append(state.id + ": background capabilities are unavailable.")
                        }
                        continue
                    }
                    guard owner.version == 1, owner.owner == state.id, let hooks = owner.agent
                    else { continue }
                    guard hooks.jobs == state.id + ".agent.jobs",
                        hooks.run == state.id + ".agent.run",
                        hooks.cancel == state.id + ".agent.cancel",
                        hooks.events == state.id + ".agent.events"
                    else {
                        missing.append(state.id + ": update the background capabilities.")
                        continue
                    }
                    do {
                        let inventory = try await call(
                            Jobs.self, gateway: gateway, state: state, operation: hooks.jobs)
                        let timeline = try await call(
                            Events.self, gateway: gateway, state: state, operation: hooks.events!)
                        guard inventory.owner == state.id, timeline.owner == state.id,
                            inventory.jobs.count <= 128, timeline.events.count <= 500,
                            inventory.jobs.allSatisfy({ owned($0, by: state.id) })
                        else {
                            throw HostCLIError.rejected("Invalid background owner projection.")
                        }
                        jobs += inventory.jobs; events += timeline.events
                    } catch is CancellationError { throw CancellationError() } catch {
                        missing.append(state.id + ": " + error.localizedDescription)
                    }
                }
                try validate(jobs: jobs, events: events)
                return .init(
                    jobs: jobs, events: Array(events.sorted { $0.date < $1.date }.suffix(500)),
                    unavailable: missing.isEmpty ? nil : missing.joined(separator: "\n"))
            },
            control: { job, cancel in
                let request = try HostCLIRequest(
                    action: .invoke, id: "host", operation: "host.cli",
                    payload: JSONEncoder().encode(
                        Envelope(arguments: ["agent", cancel ? "cancel" : "run", job, "--json"])))
                let identity = services.identity
                let flight = Task.detached {
                    try HostCLITransport.invoke(request, identity: identity)
                }
                let data = try await flight.value
                try Task.checkCancellation()
                let reply = try JSONDecoder().decode(ExtensionCLIReply.self, from: data)
                try reply.validate()
                guard reply.exitCode == 0 else { throw HostCLIError.rejected(reply.stderr) }
                let result = try JSONDecoder().decode(
                    [String: String].self, from: Data(reply.stdout.utf8))
                guard result[cancel ? "cancelled" : "queued"] == job else {
                    throw HostCLIError.rejected(
                        "The background owner did not acknowledge this job.")
                }
                await services.refresh()
            })
    }

    private static func identity(_ services: HostCoreServices) -> String? {
        guard services.online, let core = services.snapshot else { return nil }
        let marketplace = services.marketplace
        let owners = marketplace.sessions.activeIDs.sorted().map { id in
            "\(id):\(marketplace.installed[id]?.version ?? ""):"
                + "\(marketplace.sessions.versions[id] ?? ""):\(marketplace.sessions.processIdentifiers[id] ?? 0):"
                + "\(marketplace.pendingRemovalIDs.contains(id))"
        }.joined(separator: "|")
        return "\(core.pid):\(core.startedAt.timeIntervalSince1970)|\(owners)"
    }

    private static func call<T: Decodable>(
        _ type: T.Type, gateway: HostCLIGateway,
        state: HostCLIProviderState, operation: String
    ) async throws -> T {
        let invoke: HostCLIProviderRegistry.Invoke = { try await gateway.execute($0) }
        guard state.available, let pid = state.processIdentifier,
            let process = ExtensionProcessIdentity.read(pid), process.isAlive,
            try await HostCLIProviderRegistry.states(invoke: invoke).contains(state)
        else {
            throw HostCLIError.rejected("The background owner changed.")
        }
        let data = try await gateway.execute(
            HostCLIRequest(action: .invoke, id: state.id, operation: operation))
        try Task.checkCancellation()
        guard process.isAlive, ExtensionProcessIdentity.read(pid) == process,
            data.count <= HostCLIRequest.maximumPayload,
            try await HostCLIProviderRegistry.states(invoke: invoke).contains(state)
        else {
            throw HostCLIError.rejected("The background owner changed before its result arrived.")
        }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }

    private static func owned(_ job: HostBackgroundJob, by owner: String) -> Bool {
        let prefixes = [
            "herdr": "sessions.", "usage": "usage.", "machines": "machines.",
            "appMaintenance": "updates.", "cleaner": "cleaner.", "downloads": "downloads.",
            "attention": "attention.", "companion": "companion.", "codeStats": "codestats.",
        ]
        return
            (job.id.hasPrefix(owner + ".") || prefixes[owner].map { job.id.hasPrefix($0) } == true)
            && (job.descriptor.abilityID == nil || job.descriptor.abilityID == owner)
            && !["backup.sync", "backup.restore", "storage.inspect"].contains(job.id)
    }

    static func validate(jobs: [HostBackgroundJob], events: [HostBackgroundEvent]) throws {
        guard jobs.count <= 5120, events.count <= 20000,
            Set(jobs.map(\.id)).count == jobs.count, Set(events.map(\.id)).count == events.count,
            jobs.allSatisfy({ job in
                !job.id.isEmpty && job.id.utf8.count <= 128
                    && job.descriptor.title.utf8.count <= 4096
                    && ["timer", "fileSystem", "subscription", "queue"].contains(
                        job.descriptor.trigger)
                    && ["any", "pauseOnLock", "pauseOnBattery"].contains(job.descriptor.power)
                    && ["idle", "running", "paused", "disabled", "failed"].contains(job.phase)
                    && !job.id.utf8.contains(0)
                    && (job.lastDuration.map { $0.isFinite && (0...31_536_000).contains($0) }
                        ?? true)
                    && (job.lastError.map { $0.utf8.count <= 8192 && !$0.utf8.contains(0) } ?? true)
                    && (0...1_000_000).contains(job.subscribers) && job.runCount >= 0
                    && [job.descriptor.cadence.ambient, job.descriptor.cadence.live].allSatisfy {
                        $0.map { $0.isFinite && (1...31_536_000).contains($0) } ?? true
                    }
            }),
            events.allSatisfy({
                ["info", "warning", "error"].contains($0.level) && $0.message.utf8.count <= 8192
                    && $0.category.utf8.count <= 4096 && $0.name.utf8.count <= 4096
                    && ($0.duration.map { $0.isFinite && (0...31_536_000).contains($0) } ?? true)
            })
        else {
            throw HostCLIError.rejected("Invalid background job or event projection.")
        }
    }
}
