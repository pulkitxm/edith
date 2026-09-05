import Darwin
import Foundation
import Testing

@testable import EdithAgent
@testable import EdithKit

@Suite struct AgentShutdownTests {
    @Test func runtimeShutdownAwaitsRegisteredHooksAndStopsLateRegistrations() async throws {
        let runtime = AgentRuntime(build: "fixture", store: nil)
        let gate = ShutdownTestGate()
        await runtime.register(operation: "fixture") { _ in Data() }
        await runtime.registerShutdown(id: "existing") { await gate.wait() }
        let first = Task { await runtime.shutdown() }
        try await eventually { await gate.entered == 1 }
        #expect(await runtime.isShuttingDown)
        await #expect(throws: AgentError.self) {
            _ = try await runtime.perform(operation: "fixture", payload: Data())
        }
        let second = Task { await runtime.shutdown() }
        await gate.release()
        await first.value
        await second.value
        await runtime.registerShutdown(id: "late") { await gate.enter() }
        await runtime.shutdown()
        #expect(await gate.entered == 2)
        await runtime.register(operation: "too-late") { _ in Data() }
        #expect(await runtime.registeredOperations == ["fixture"])
    }

    @Test func taskShutdownKillsItsChildAndPersistsInterruptedQueuedWork() async throws {
        let directory = try sandbox()
        defer { try? FileManager.default.removeItem(at: directory) }
        let tasks = try AgentTaskService(
            directory: directory.appendingPathComponent("tasks"),
            limits: AgentTaskLimits(concurrency: 1))
        await tasks.registerCommand()
        let first = try command(
            "sleep 30 & child=$!; printf '%s\\n' \"$child\" > child.pid; wait", directory: directory
        )
        let queued = try command("touch queued-started", directory: directory)
        _ = try await tasks.submit(first)
        _ = try await tasks.submit(queued)
        let pid = try await childPID(in: directory)
        defer { _ = kill(pid, SIGKILL) }
        #expect(kill(pid, 0) == 0)
        await tasks.shutdown()
        try await eventually { kill(pid, 0) != 0 }
        #expect(try await tasks.status(first.id).snapshot.state == .interrupted)
        #expect(try await tasks.status(queued.id).snapshot.state == .interrupted)
        #expect(
            !FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("queued-started").path))
        await #expect(throws: AgentError.self) { _ = try await tasks.submit(first) }
        let restored = try AgentTaskService(directory: directory.appendingPathComponent("tasks"))
        #expect(try await restored.status(first.id).snapshot.state == .interrupted)
        #expect(try await restored.status(queued.id).snapshot.state == .interrupted)
    }

    @Test func schedulerShutdownAwaitsExecutionAndCannotBeRestarted() async throws {
        let gate = ShutdownTestGate()
        let scheduler = JobScheduler()
        await scheduler.register(
            AgentJob(
                descriptor: AgentJobDescriptor(
                    id: "fixture", title: "Fixture", trigger: .timer, topic: .usage,
                    cadence: .onDemand)
            ) {
                await gate.wait()
                try Task.checkCancellation()
                return Data()
            })
        #expect(await scheduler.enqueue("fixture"))
        try await eventually { await gate.entered == 1 }
        let shutdown = Task {
            await scheduler.shutdown(); await gate.complete()
        }
        try await eventually { await scheduler.snapshots.first?.phase != .running }
        #expect(await gate.completed == false)
        await scheduler.start()
        #expect(await scheduler.enqueue("fixture") == false)
        #expect(await scheduler.runNow("fixture") == nil)
        await gate.release()
        await shutdown.value
        #expect(await gate.completed)
        #expect(await gate.entered == 1)
    }

    @Test func servicesWaitForCancelledStartupAndRunItsLateCleanup() async throws {
        let runtime = AgentRuntime(build: "fixture", store: nil)
        let gate = ShutdownTestGate()
        let cleanup = ShutdownTestGate()
        let startup = Task {
            await gate.wait()
            await runtime.registerShutdown(id: "late") { await cleanup.enter() }
        }
        try await eventually { await gate.entered == 1 }
        let services = AgentServices(
            runtime: runtime, hub: AgentHub(runtime: runtime),
            scheduler: JobScheduler(), watchers: [], startup: startup)
        let stop = Task {
            await services.stop(); await gate.complete()
        }
        try await eventually { await runtime.isShuttingDown }
        #expect(await gate.completed == false)
        await gate.release()
        await stop.value
        #expect(await cleanup.entered == 1)
        #expect(await gate.completed)
    }

    private func command(_ script: String, directory: URL) throws -> AgentTaskSubmission {
        AgentTaskSubmission(
            operation: AgentTaskOperation.command, title: "Shutdown fixture",
            payload: try AgentPayload.encode(
                CLICommandRequest(
                    executableURL: URL(fileURLWithPath: "/bin/sh"),
                    arguments: ["-c", script], environment: [:],
                    currentDirectoryURL: directory, timeout: 60)))
    }

    private func sandbox() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "shutdown-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func childPID(in directory: URL) async throws -> Int32 {
        let file = directory.appendingPathComponent("child.pid")
        try await eventually {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { return false }
            return Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) != nil
        }
        return try #require(
            Int32(
                String(contentsOf: file, encoding: .utf8).trimmingCharacters(
                    in: .whitespacesAndNewlines)))
    }

    private func eventually(_ condition: @escaping @Sendable () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await condition()), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await condition())
    }
}

private actor ShutdownTestGate {
    var entered = 0
    var completed = false
    private var waiting: CheckedContinuation<Void, Never>?
    func enter() { entered += 1 }
    func complete() { completed = true }
    func wait() async {
        entered += 1
        await withCheckedContinuation { waiting = $0 }
    }
    func release() {
        waiting?.resume()
        waiting = nil
    }
}
