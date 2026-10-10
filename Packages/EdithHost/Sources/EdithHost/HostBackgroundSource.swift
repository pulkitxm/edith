import EdithExtensionSupport
import EdithHostCore
import Foundation

@MainActor enum HostBackgroundSource {
    private struct CoreProjection: Decodable {
        struct Agent: Decodable {
            let jobs: [HostBackgroundJob]
            let events: [HostBackgroundEvent]
            let schemaVersion: Int
            let protocolVersion: Int
        }
        let agent: Agent?
    }
    static func live(_ services: HostCoreServices) -> HostBackgroundEnvironment {
        let gateway = HostCLIGateway(marketplace: services.marketplace)
        let invoke: HostCLIProviderRegistry.Invoke = { try await gateway.execute($0) }
        let hooks = HostCoreOwnerHooks(invoke: invoke)
        let agent = HostCoreAgentCLIFactory.make(
            local: HostCoreAgentCLIAdapter.backend(core: { services }), invoke: invoke)
        return HostBackgroundEnvironment(
            identity: { identity(services) },
            read: {
                guard let snapshot = services.snapshot, services.online else {
                    throw HostCLIError.unavailable
                }
                let core = try decodeCore(JSONEncoder().encode(snapshot))
                guard core.unavailable == nil else { return core }
                var jobs = core.jobs
                var events = core.events
                var unavailable: String?
                do {
                    let ownedJobs = try await hooks.jobs()
                    let ownedEvents = try await hooks.events()
                    let decoder = JSONDecoder()
                    jobs += try decoder.decode(
                        [HostBackgroundJob].self, from: JSONEncoder().encode(ownedJobs))
                    events += try decoder.decode(
                        [HostBackgroundEvent].self, from: JSONEncoder().encode(ownedEvents))
                } catch is CancellationError { throw CancellationError() } catch {
                    if let command = error as? HostCoreCommandFailure {
                        unavailable = command.message + (command.hint.map { "\n" + $0 } ?? "")
                    } else {
                        unavailable = error.localizedDescription
                    }
                }
                try validate(jobs: jobs, events: events)
                return .init(
                    jobs: jobs, events: Array(events.sorted { $0.date < $1.date }.suffix(500)),
                    unavailable: unavailable)
            },
            control: { job, cancel in
                let reply = try await agent.execute([cancel ? "cancel" : "run", job, "--json"])
                try Task.checkCancellation()
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

    static func policy(_ services: HostCoreServices) -> HostBackgroundPolicyEnvironment {
        .init(
            owner: {
                guard let identity = identity(services), let snapshot = services.snapshot else {
                    return nil
                }
                return .init(identity: identity, processIdentifier: snapshot.pid)
            },
            read: { try await services.backgroundPolicy() },
            set: { try await services.setBackgroundPolicy(pauseAmbientOnBattery: $0) })
    }

    static func decodeCore(_ data: Data) throws -> HostBackgroundProjection {
        guard data.count <= HostCLIRequest.maximumPayload else {
            throw HostCLIError.rejected("The background projection exceeds its size limit.")
        }
        let core = try JSONDecoder().decode(CoreProjection.self, from: data)
        guard let agent = core.agent, agent.schemaVersion == 1, agent.protocolVersion == 1 else {
            return .init(
                jobs: [], events: [],
                unavailable:
                    "This background service does not expose a supported job inventory or event timeline. Update Edith to use these controls."
            )
        }
        guard agent.jobs.count <= 128, agent.events.count <= 500 else {
            throw HostCLIError.rejected("The background projection exceeds its item limit.")
        }
        try validate(jobs: agent.jobs, events: agent.events)
        return .init(jobs: agent.jobs, events: agent.events, unavailable: nil)
    }

    private static func identity(_ services: HostCoreServices) -> String? {
        guard services.online, let core = services.snapshot else { return nil }
        let marketplace = services.marketplace
        let owners = marketplace.sessions.activeIDs.sorted().map { id in
            "\(id):\(marketplace.installed[id]?.version ?? ""):"
                + "\(marketplace.sessions.versions[id] ?? ""):\(marketplace.sessions.processIdentifiers[id] ?? 0):"
                + "\(marketplace.pendingRemovalIDs.contains(id)):\(marketplace.sessions.pendingDisableIDs.contains(id))"
        }.joined(separator: "|")
        return "\(core.pid):\(core.startedAt.timeIntervalSince1970)|\(owners)"
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
