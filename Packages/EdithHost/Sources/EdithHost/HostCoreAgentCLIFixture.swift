#if EDITH_CLI_FIXTURE
import Darwin
import EdithHostCore
import EdithExtensionSupport
import Foundation

@MainActor final class HostCoreAgentCLIFixture {
    private let identity: HostIdentity
    private let executable: URL
    private let directory: URL
    private var process: HostCoreProcess?
    private var previous: HostCoreSnapshot?
    private var statusFlight: Task<HostCoreSnapshot, Error>?
    private var flights: [String: Task<Void, Never>] = [:]
    private var callbacks: [String] = []
    private var stoppedPIDs: [Int32] = []
    private var stopping = false

    init(identity: HostIdentity, executable: URL, directory: URL) {
        self.identity = identity; self.executable = executable; self.directory = directory
    }

    var backend: HostCoreAgentCLIBackend {
        .init(
            ownedJobs: { [self] in
                guard !stopping, let process, process.ready,
                    process.processIdentifier == previous?.pid
                else { return [] }
                return Set(previous?.agent?.jobs.map(\.id) ?? [])
            },
            status: { [self] in
                try record("status")
                let next = try await snapshot()
                let elapsed =
                    previous.map { next.collectedAt.timeIntervalSince($0.collectedAt) } ?? 0
                let cpu =
                    elapsed > 0 && previous?.pid == next.pid
                    ? max(0, (next.cpuSeconds - (previous?.cpuSeconds ?? 0)) / elapsed * 100) : 0
                previous = next
                return try HostCoreAgentStatus(snapshot: next, cpuPercent: cpu)
            },
            jobs: { [self] in
                try record("jobs")
                guard let agent = try await snapshot().agent else {
                    throw HostWorkerError.invalidResponse
                }
                return agent.jobs
            },
            restart: { [self] in
                try record("restart")
                await drain()
                try await start()
            },
            logs: { [self] last in
                try record("logs:" + last)
                let cutoff = Date().addingTimeInterval(-(try HostCoreAgentCLI.logWindow(last)))
                guard let agent = try await snapshot().agent else {
                    throw HostWorkerError.invalidResponse
                }
                return agent.events.filter { $0.date >= cutoff }.map {
                    "\($0.date.ISO8601Format()) [\($0.level.rawValue)] \($0.name): \($0.message)"
                }
            },
            events: { [self] in
                try record("events")
                guard let agent = try await snapshot().agent else {
                    throw HostWorkerError.invalidResponse
                }
                return agent.events
            },
            run: { [self] job in
                guard !stopping, let process, process.ready, flights.isEmpty,
                    let operation: HostCoreOperation = [
                        "storage.inspect": .inspect, "backup.sync": .synchronize,
                        "backup.restore": .restore,
                    ][job]
                else { throw HostCoreCommandFailure("The owned fixture job is unavailable.") }
                try record("run:" + job)
                flights[job] = Task { [self] in
                    defer { flights.removeValue(forKey: job) }
                    do { _ = try await process.perform(operation) } catch is CancellationError {
                        try? record("cancelled:" + job)
                    } catch { try? record("failed:" + job) }
                }
            },
            cancel: { [self] job in
                guard !stopping, let process, let flight = flights[job], process.cancelCurrentTask()
                else {
                    throw HostCoreCommandFailure("The owned fixture job is not pending.")
                }
                try record("cancel:" + job + ":sent")
                flight.cancel()
            })
    }

    func start() async throws {
        guard process == nil else { throw HostWorkerError.rejected }
        stopping = false
        let next = HostCoreProcess(identity: identity, executable: executable)
        process = next
        do {
            let snapshot = try await next.start()
            previous = snapshot
            try JSONSerialization.data(withJSONObject: ["pid": snapshot.pid, "owner": getpid()])
                .write(to: directory.appendingPathComponent("core-ready.json"), options: .atomic)
        } catch { await next.stop(); process = nil; throw error }
    }

    func shutdown() async {
        stopping = true
        try? record("shutdown")
        await drain()
        try? JSONSerialization.data(withJSONObject: [
            "callbacks": callbacks, "stoppedPIDs": stoppedPIDs,
            "ownedCoreProcesses": process == nil ? 0 : 1,
        ]).write(to: directory.appendingPathComponent("core-callbacks.json"), options: .atomic)
        SharedDefaults.applicationStore(identifier: identity.identifier)?
            .removePersistentDomain(forName: identity.identifier)
    }

    private func drain() async {
        let tasks = Array(flights.values)
        process?.cancelCurrentTask()
        tasks.forEach { $0.cancel() }
        for task in tasks { await task.value }
        flights.removeAll()
        statusFlight?.cancel(); _ = try? await statusFlight?.value; statusFlight = nil
        if let process {
            if let pid = process.processIdentifier { stoppedPIDs.append(pid) }
            await process.stop()
            precondition(!process.ready && process.processIdentifier == nil)
        }
        process = nil; previous = nil
    }

    private func snapshot() async throws -> HostCoreSnapshot {
        guard !stopping, let process, process.ready else {
            throw HostCoreCommandFailure(
                "background agent", hint: "The owned fixture core is offline.")
        }
        if let statusFlight { return try await statusFlight.value }
        let task = Task { try await process.perform(.status) }
        statusFlight = task
        defer { statusFlight = nil }
        return try await task.value
    }

    private func record(_ value: String) throws {
        callbacks.append(value)
        try JSONSerialization.data(withJSONObject: [
            "callbacks": callbacks, "stoppedPIDs": stoppedPIDs,
        ])
        .write(to: directory.appendingPathComponent("core-callbacks.json"), options: .atomic)
    }
}
#endif
