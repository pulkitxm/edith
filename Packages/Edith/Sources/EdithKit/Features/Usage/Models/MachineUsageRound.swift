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
    public let keepReconnecting: @Sendable () -> Bool

    public init(
        machine: Machine, slug: String, history: MachineUsageSummary?, directory: URL,
        timeout: TimeInterval, keepReconnecting: @escaping @Sendable () -> Bool = { false }
    ) {
        self.machine = machine
        self.slug = slug
        self.history = history
        self.directory = directory
        self.timeout = timeout
        self.keepReconnecting = keepReconnecting
    }
}

public enum MachineUsageRound {
    public typealias Attempt =
        @Sendable (MachineUsageAttempt) async throws -> MachineUsageCollection

    public static let interval: TimeInterval = 1800
    public static let setupAllowance: TimeInterval = 120
    public static let maximumConcurrentMachines = 8
    public static let reconnectWindow: TimeInterval = 120

    public static func deadline(timeout: TimeInterval) -> TimeInterval {
        timeout + setupAllowance
    }

    public static func roundDeadline(machines: Int, timeout: TimeInterval) -> TimeInterval {
        let waves = (max(machines, 1) + maximumConcurrentMachines - 1) / maximumConcurrentMachines
        return deadline(timeout: timeout) * TimeInterval(waves)
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
        keepReconnecting: @escaping @Sendable () -> Bool = { false },
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
                history: bindings.summaries[machine.id], directory: directory, timeout: timeout,
                keepReconnecting: keepReconnecting)
        }
        let cutoff = deadline(timeout: timeout)
        let outcomes = await withTaskGroup(
            of: (Int, Result<MachineUsageCollection, Error>, TimeInterval).self
        ) { group in
            var ordered = [Result<MachineUsageCollection, Error>?](
                repeating: nil, count: attempts.count)
            var started = 0
            while started < attempts.count, started < maximumConcurrentMachines {
                let index = started
                group.addTask { await run(attempts[index], at: index, cutoff, attempt) }
                started += 1
            }
            while let (index, outcome, seconds) = await group.next() {
                ordered[index] = outcome
                report(
                    outcome, from: attempts[index].machine, seconds: seconds, verbose: verbose,
                    onEvent: onEvent)
                if started < attempts.count {
                    let next = started
                    group.addTask { await run(attempts[next], at: next, cutoff, attempt) }
                    started += 1
                }
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

    private static func run(
        _ input: MachineUsageAttempt, at index: Int, _ cutoff: TimeInterval,
        _ attempt: @escaping Attempt
    ) async -> (Int, Result<MachineUsageCollection, Error>, TimeInterval) {
        let startedAt = Date()
        do {
            let run = try await withinDeadline(cutoff, machine: input.machine.name) {
                try await attempt(input)
            }
            return (index, .success(run), Date().timeIntervalSince(startedAt))
        } catch {
            return (index, .failure(error), Date().timeIntervalSince(startedAt))
        }
    }

    @Sendable public static func overSSH(_ input: MachineUsageAttempt) async throws
        -> MachineUsageCollection
    {
        let connection = SSHConnection(
            machine: input.machine, connectTimeout: input.machine.reach.connectTimeout)
        do {
            try await reconnecting(while: input.keepReconnecting) {
                try await connection.connect()
            }
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

    static func reconnecting(
        while keepReconnecting: @escaping @Sendable () -> Bool,
        pause: Duration = .seconds(1), longestPause: Duration = .seconds(8),
        _ connect: @escaping @Sendable () async throws -> Void
    ) async throws {
        var failure: SSHConnectFailure
        do {
            try await connect()
            return
        } catch let SSHConnectionError.connectFailed(dropped) where dropped.isRecoverable {
            failure = dropped
        }
        try await Task.sleep(for: pause)
        var wait = pause
        var guaranteed = true
        while true {
            do {
                if guaranteed {
                    try await connect()
                } else {
                    guard try await finishes(unless: keepReconnecting, connect) else { break }
                }
                return
            } catch let SSHConnectionError.connectFailed(dropped) where dropped.isRecoverable {
                failure = dropped
            }
            guaranteed = false
            wait = min(wait * 2, longestPause)
            let paused = try await finishes(unless: keepReconnecting) {
                try await Task.sleep(for: wait)
            }
            guard paused else { break }
        }
        throw SSHConnectionError.connectFailed(failure)
    }

    static func finishes(
        unless keepGoing: @escaping @Sendable () -> Bool,
        _ body: @escaping @Sendable () async throws -> Void
    ) async throws -> Bool {
        guard keepGoing() else { return false }
        return try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask {
                try await body()
                return true
            }
            group.addTask {
                while keepGoing() { try await Task.sleep(for: .milliseconds(100)) }
                return false
            }
            defer { group.cancelAll() }
            return try await group.next() ?? false
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
