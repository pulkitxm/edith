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

public struct MachineUsageAttempt: Sendable {
    public let machine: Machine
    public let slug: String
    public let history: MachineUsageSummary?
    public let directory: URL
    public let timeout: TimeInterval

    public init(
        machine: Machine, slug: String, history: MachineUsageSummary?, directory: URL,
        timeout: TimeInterval
    ) {
        self.machine = machine
        self.slug = slug
        self.history = history
        self.directory = directory
        self.timeout = timeout
    }
}

public enum MachineUsageRound {
    public typealias Attempt =
        @Sendable (MachineUsageAttempt) async throws -> MachineUsageCollection

    public static let interval: TimeInterval = 1800
    public static let setupAllowance: TimeInterval = 120

    public static func deadline(timeout: TimeInterval) -> TimeInterval {
        timeout + setupAllowance
    }

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
        let machines = MachineRegistry.machines()
        let bindings = MachineUsageBindings(machines: machines)
        return due(
            bindings.included(machines, selected: MachineUsageSelection.machineIDs()),
            force: force, now: now,
            collectedAt: { bindings.summaries[$0]?.collectedAt })
    }

    public static func collect(
        _ machines: [Machine],
        registry: [Machine] = MachineRegistry.machines(),
        dataDir: URL = Repo.dataDir,
        timeout: TimeInterval = MachineUsageCollector.defaultTimeout,
        echoingTheCollector verbose: Bool = false,
        onEvent: @escaping @Sendable (UsageRefreshEvent) -> Void = { _ in },
        attempt: @escaping Attempt = overSSH
    ) async -> MachineUsageRoundResult {
        guard !machines.isEmpty else { return MachineUsageRoundResult() }
        try? FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        guard let lock = UsageRefreshLock.acquire(at: lockURL(dataDir: dataDir)) else {
            return MachineUsageRoundResult(skippedBecauseBusy: true)
        }
        defer { lock.release() }

        let slugs = MachineUsageSlug.slugs(for: registry.isEmpty ? machines : registry)
        let directory = dataDir.appendingPathComponent("machines")
        let bindings = MachineUsageBindings(machines: registry, directory: directory)
        let attempts = machines.map { machine in
            MachineUsageAttempt(
                machine: machine,
                slug: slugs[machine.id] ?? MachineUsageSlug.slug(for: machine.name),
                history: bindings.summaries[machine.id], directory: directory, timeout: timeout)
        }
        let limit = deadline(timeout: timeout)
        let outcomes = await withTaskGroup(
            of: (Int, Result<MachineUsageCollection, Error>, TimeInterval).self
        ) { group in
            for (index, input) in attempts.enumerated() {
                group.addTask {
                    let startedAt = Date()
                    do {
                        let run = try await withinDeadline(limit, machine: input.machine.name) {
                            try await attempt(input)
                        }
                        return (index, .success(run), Date().timeIntervalSince(startedAt))
                    } catch {
                        return (index, .failure(error), Date().timeIntervalSince(startedAt))
                    }
                }
            }
            var ordered = [Result<MachineUsageCollection, Error>?](
                repeating: nil, count: attempts.count)
            for await (index, outcome, seconds) in group {
                ordered[index] = outcome
                report(
                    outcome, from: attempts[index].machine, seconds: seconds, verbose: verbose,
                    onEvent: onEvent)
            }
            return ordered
        }
        var result = MachineUsageRoundResult()
        for (machine, outcome) in zip(machines, outcomes) {
            switch outcome {
            case let .success(run): result.collected.append(run.summary)
            case let .failure(error):
                result.failures.append((machine.name, error.localizedDescription))
            case nil: break
            }
        }
        return result
    }

    @Sendable public static func overSSH(_ input: MachineUsageAttempt) async throws
        -> MachineUsageCollection
    {
        let connection = SSHConnection(
            machine: input.machine, connectTimeout: input.machine.reach.connectTimeout)
        do {
            try await retryingOnceWhenRecoverable { try await connection.connect() }
            let run = try await withOneRetryOnADroppedLink(connection) {
                try await MachineUsageCollector.collect(
                    machine: input.machine, slug: input.slug, over: connection,
                    timeout: input.timeout, history: input.history, directory: input.directory)
            }
            await connection.disconnect()
            return run
        } catch {
            await connection.disconnect()
            throw error
        }
    }

    static func retryingOnceWhenRecoverable(
        pause: Duration = .seconds(1), _ connect: () async throws -> Void
    ) async throws {
        do {
            try await connect()
        } catch let SSHConnectionError.connectFailed(failure) where failure.isRecoverable {
            try await Task.sleep(for: pause)
            try await connect()
        }
    }

    static func withinDeadline<Value: Sendable>(
        _ seconds: TimeInterval, machine: String,
        _ body: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try await withThrowingTaskGroup(of: Value?.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                return nil
            }
            defer { group.cancelAll() }
            guard let first = try await group.next(), let value = first else {
                throw MachineUsageError.timedOut(machine, seconds: Int(seconds.rounded(.up)))
            }
            return value
        }
    }

    private static func report(
        _ outcome: Result<MachineUsageCollection, Error>, from machine: Machine,
        seconds: TimeInterval, verbose: Bool,
        onEvent: @Sendable (UsageRefreshEvent) -> Void
    ) {
        switch outcome {
        case let .success(run):
            if verbose {
                for line in run.log.split(separator: "\n") {
                    let text = line.trimmingCharacters(in: .whitespaces)
                    if !text.isEmpty { onEvent(.note(text)) }
                }
            }
            onEvent(.phase(name: machine.name, detail: describe(run.summary), seconds: seconds))
        case let .failure(error):
            onEvent(.note("\(machine.name): \(error.localizedDescription)"))
        }
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
