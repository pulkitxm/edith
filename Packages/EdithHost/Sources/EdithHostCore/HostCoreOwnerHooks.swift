import EdithExtensionSupport
import Foundation

public struct HostCoreOwnerHooks: Sendable {
    private struct Jobs: Decodable { let owner: String; let jobs: [HostCoreJobSnapshot] }
    private struct Events: Decodable { let owner: String; let events: [HostCoreAgentEvent] }
    private struct Logs: Decodable { let owner: String; let lines: [String] }
    private struct Acknowledgement: Decodable {
        let owner: String; let job: String; let accepted: Bool
    }
    private let invoke: HostCLIProviderRegistry.Invoke
    public init(invoke: @escaping HostCLIProviderRegistry.Invoke) { self.invoke = invoke }

    public func jobs() async throws -> [HostCoreJobSnapshot] {
        let registry = try await HostCoreOwnerRegistry.load(invoke: invoke)
        for state in registry.states
        where state.available && Self.originalOwners.values.contains(state.id) {
            guard
                registry.providers.contains(where: {
                    $0.state.id == state.id && $0.catalog.agent != nil
                })
            else {
                throw HostCoreCommandFailure(
                    "The original agent job inventory is unavailable for " + state.id,
                    hint: "Update " + state.id
                        + " to an extension with owned agent job hooks, then retry ed agent jobs.")
            }
        }
        var jobs: [HostCoreJobSnapshot] = []
        for provider in registry.providers where provider.catalog.agent != nil {
            jobs += try await inventory(registry: registry, provider: provider)
        }
        guard Set(jobs.map(\.id)).count == jobs.count else {
            throw HostCoreCommandFailure(
                "Multiple extensions claimed the same background job.",
                hint: "Update the conflicting extensions and retry ed agent jobs.")
        }
        return jobs
    }

    public func control(job: String, cancel: Bool) async throws {
        let registry = try await HostCoreOwnerRegistry.load(invoke: invoke)
        var owners: [HostCoreOwnerRegistry.Provider] = []
        for provider in registry.providers where provider.catalog.agent != nil {
            if try await inventory(registry: registry, provider: provider).contains(where: {
                $0.id == job
            }) {
                owners.append(provider)
            }
        }
        guard owners.count == 1, let provider = owners.first, let agent = provider.catalog.agent,
            let operation = cancel ? agent.cancel : agent.run
        else {
            let owner = Self.originalOwners.first { job.hasPrefix($0.key) }?.value
            throw HostCoreCommandFailure(
                "The background job is unavailable: " + job,
                hint: owner.map {
                    "Install and enable " + $0
                        + " with owned agent job hooks, then retry ed agent jobs."
                }
                    ?? "Choose a job from ed agent jobs.",
                code: owner == nil && owners.isEmpty ? 3 : 4)
        }
        let ack = try await registry.call(
            Acknowledgement.self, provider: provider, operation: operation,
            payload: HostCLIJSON.object(["job": .string(job)]).encoded())
        guard ack.owner == provider.state.id, ack.job == job, ack.accepted else {
            throw HostCoreCommandFailure(
                "The owning extension did not accept the job action.",
                hint: "Check ed extensions doctor " + provider.state.id)
        }
    }

    public func events() async throws -> [HostCoreAgentEvent] {
        let registry = try await HostCoreOwnerRegistry.load(invoke: invoke)
        var events: [HostCoreAgentEvent] = []
        for provider in registry.providers {
            guard let operation = provider.catalog.agent?.events else { continue }
            let reply = try await registry.call(
                Events.self, provider: provider, operation: operation)
            guard reply.owner == provider.state.id, reply.events.count <= 500,
                Set(reply.events.map(\.id)).count == reply.events.count,
                reply.events.allSatisfy({
                    HostCoreReadinessReport.text($0.category)
                        && HostCoreReadinessReport.text($0.name)
                        && HostCoreReadinessReport.text($0.message)
                        && ($0.duration.map { $0.isFinite && (0...31_536_000).contains($0) } ?? true)
                })
            else { throw HostCLIError.rejected("Invalid owning agent events.") }
            events += reply.events
        }
        return events
    }

    public func logs(last: String) async throws -> [String] {
        _ = try await HostCoreAgentCLI.logWindow(last)
        let registry = try await HostCoreOwnerRegistry.load(invoke: invoke)
        var lines: [String] = []
        for provider in registry.providers {
            guard let operation = provider.catalog.agent?.logs else { continue }
            let reply = try await registry.call(
                Logs.self, provider: provider, operation: operation,
                payload: HostCLIJSON.object(["last": .string(last)]).encoded())
            guard reply.owner == provider.state.id, reply.lines.count <= 4096,
                reply.lines.allSatisfy({
                    $0.utf8.count <= 4096 && !$0.utf8.contains(0) && !$0.contains("\n")
                })
            else { throw HostCLIError.rejected("Invalid owning agent log lines.") }
            lines += reply.lines
        }
        return lines
    }

    public func readiness(id: String, operation: String, title: String) async throws
        -> HostCoreReadinessReport
    {
        let registry = try await HostCoreOwnerRegistry.load(invoke: invoke)
        guard let state = registry.states.first(where: { $0.id == id }) else {
            throw HostCoreCommandFailure(
                "no extension named " + id,
                hint: "known ids: " + registry.states.map(\.id).joined(separator: ", "), code: 3)
        }
        guard let provider = registry.providers.first(where: { $0.state.id == id }),
            let hook = provider.catalog.readiness?.inspect
        else {
            return .unavailable(
                state: state, title: title,
                detail: registry.issues[id]
                    ?? "The extension is not running with an owning readiness provider.")
        }
        do {
            let report = try await registry.call(
                HostCoreReadinessReport.self, provider: provider,
                operation: hook,
                payload: HostCLIJSON.object(["operation": .string(operation)]).encoded())
            try report.validate(owner: id)
            return report
        } catch is CancellationError { throw CancellationError() } catch {
            let current = try await HostCLIProviderRegistry.states(invoke: invoke)
            guard let state = current.first(where: { $0.id == id }) else { throw error }
            return .unavailable(
                state: state, title: title,
                detail: "The owning readiness check failed: "
                    + String(error.localizedDescription.prefix(3000)))
        }
    }

    public func setup(id: String, dryRun: Bool, installTools: Bool) async throws
        -> HostCoreReadinessSetup
    {
        let registry = try await HostCoreOwnerRegistry.load(invoke: invoke)
        guard let provider = registry.providers.first(where: { $0.state.id == id }),
            let operation = provider.catalog.readiness?.setup
        else {
            throw HostCoreCommandFailure(
                "The owning setup provider is unavailable for " + id,
                hint: "Install and enable a compatible " + id
                    + " extension with readiness hooks, then retry setup. No tools or enablement were changed."
            )
        }
        let reply = try await registry.call(
            HostCoreReadinessSetup.self, provider: provider, operation: operation,
            payload: HostCLIJSON.object([
                "dryRun": .bool(dryRun), "installTools": .bool(installTools),
            ]).encoded(), timeout: 120)
        try reply.validate(owner: id, dryRun: dryRun, installTools: installTools)
        return reply
    }

    private func inventory(
        registry: HostCoreOwnerRegistry, provider: HostCoreOwnerRegistry.Provider
    ) async throws -> [HostCoreJobSnapshot] {
        guard let agent = provider.catalog.agent else { return [] }
        let result = try await registry.call(Jobs.self, provider: provider, operation: agent.jobs)
        guard result.owner == provider.state.id, result.jobs.count <= 128,
            Set(result.jobs.map(\.id)).count == result.jobs.count,
            result.jobs.allSatisfy({ Self.valid($0, owner: provider.state.id) })
        else { throw HostCLIError.rejected("Invalid owning background job inventory.") }
        return result.jobs
    }

    private static func valid(_ job: HostCoreJobSnapshot, owner: String) -> Bool {
        let prefixes = originalOwners.filter { $0.value == owner }.map(\.key) + [owner + "."]
        return prefixes.contains(where: { job.id.hasPrefix($0) })
            && !HostCoreAgentStore.descriptors.contains(where: { $0.id == job.id })
            && HostCoreReadinessReport.text(job.id) && job.id.utf8.count <= 128
            && HostCoreReadinessReport.text(job.descriptor.title)
            && (job.descriptor.topic.map { $0.utf8.count <= 128 && !$0.utf8.contains(0) } ?? true)
            && (job.descriptor.abilityID == nil || job.descriptor.abilityID == owner)
            && [job.descriptor.cadence.ambient, job.descriptor.cadence.live].allSatisfy({
                $0.map { $0.isFinite && (1...31_536_000).contains($0) } ?? true
            }) && (0...1_000_000).contains(job.subscribers) && (0..<Int.max).contains(job.runCount)
            && (job.lastDuration.map { $0.isFinite && (0...31_536_000).contains($0) } ?? true)
            && (job.lastError.map(HostCoreReadinessReport.text) ?? true)
    }

    private static let originalOwners = [
        "usage.": "usage", "sessions.": "herdr", "machines.": "machines",
        "updates.": "appMaintenance", "cleaner.": "cleaner", "downloads.": "downloads",
        "attention.": "attention", "companion.": "companion", "codeStats.": "codeStats",
    ]
}
