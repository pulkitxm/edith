import Foundation

public struct MachineUsageRoundResult: Sendable {
    public var collected: [MachineUsageSummary]
    public var failures: [(machine: String, reason: String)]
    public var skippedBecauseBusy: Bool

    public init(
        collected: [MachineUsageSummary] = [],
        failures: [(machine: String, reason: String)] = [],
        skippedBecauseBusy: Bool = false
    ) {
        self.collected = collected
        self.failures = failures
        self.skippedBecauseBusy = skippedBecauseBusy
    }

    public var changedAnything: Bool { !collected.isEmpty }
}

public enum MachineUsageRound {
    public static let interval: TimeInterval = 1800

    public static func lockURL(dataDir: URL = Repo.dataDir) -> URL {
        dataDir.appendingPathComponent("machines.lock")
    }

    public static func due(
        _ machines: [Machine], force: Bool, now: Date = Date(),
        collectedAt: (UUID) -> Date?
    ) -> [Machine] {
        machines.filter { machine in
            guard !force else { return true }
            guard let last = collectedAt(machine.id) else { return true }
            return now.timeIntervalSince(last) >= interval
        }
    }

    public static func due(force: Bool, now: Date = Date()) -> [Machine] {
        due(
            MachineUsageSelection.included(in: MachineRegistry.machines()), force: force, now: now,
            collectedAt: { MachineUsageStore.summary(machineID: $0)?.collectedAt })
    }

    public static func collect(
        _ machines: [Machine],
        registry: [Machine] = MachineRegistry.machines(),
        dataDir: URL = Repo.dataDir,
        timeout: TimeInterval = MachineUsageCollector.defaultTimeout,
        echoingTheCollector verbose: Bool = false,
        onEvent: @escaping @Sendable (UsageRefreshEvent) -> Void = { _ in }
    ) async -> MachineUsageRoundResult {
        guard !machines.isEmpty else { return MachineUsageRoundResult() }
        try? FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        guard let lock = UsageRefreshLock.acquire(at: lockURL(dataDir: dataDir)) else {
            return MachineUsageRoundResult(skippedBecauseBusy: true)
        }
        defer { lock.release() }

        let slugs = MachineUsageSlug.slugs(for: registry.isEmpty ? machines : registry)
        var result = MachineUsageRoundResult()
        for machine in machines {
            let startedAt = Date()
            let slug = slugs[machine.id] ?? MachineUsageSlug.slug(for: machine.name)
            let connection = SSHConnection(machine: machine)
            do {
                try await connection.connect()
                let run = try await withOneRetryOnADroppedLink(connection) {
                    try await MachineUsageCollector.collect(
                        machine: machine, slug: slug, over: connection, timeout: timeout)
                }
                result.collected.append(run.summary)
                if verbose {
                    for line in run.log.split(separator: "\n") {
                        let text = line.trimmingCharacters(in: .whitespaces)
                        if !text.isEmpty { onEvent(.note(text)) }
                    }
                }
                onEvent(
                    .phase(
                        name: machine.name, detail: describe(run.summary),
                        seconds: Date().timeIntervalSince(startedAt)))
            } catch {
                let reason = error.localizedDescription
                result.failures.append((machine.name, reason))
                onEvent(.note("\(machine.name): \(reason)"))
            }
        }
        MachineUsageStore.prune(keeping: registry.map(\.id))
        return result
    }

    static func withOneRetryOnADroppedLink(
        _ connection: SSHConnection,
        _ body: () async throws -> MachineUsageCollection
    ) async throws -> MachineUsageCollection {
        do {
            return try await body()
        } catch let error as MachineUsageError {
            guard case let .collectorFailed(_, status, _) = error,
                status == MachineUsageCollector.transportFailure
            else { throw error }
            await connection.disconnect()
            try await connection.connect()
            return try await body()
        }
    }

    public static func describe(_ summary: MachineUsageSummary) -> String {
        let agents = summary.sources.count == 1 ? "1 agent" : "\(summary.sources.count) agents"
        return "\(summary.days) days · \(agents)"
    }
}
