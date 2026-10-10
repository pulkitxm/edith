import Darwin
import Foundation
import Testing

@testable import EdithHostCore

@Suite @MainActor struct HostCoreAgentCLITests {
    @Test func originalCallbacksRepliesAndInvalidOptionsArePreserved() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "core-cli-" + UUID().uuidString)
        let identity = try HostIdentity(
            identifier: "com.pulkit.edith.tests.core-" + UUID().uuidString, supportDirectory: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = try HostCoreRuntime(identity: identity)
        var actions: [String] = []
        let cli = HostCoreAgentCLI(
            backend: HostCoreAgentCLIBackend(
                status: { try HostCoreAgentStatus(snapshot: runtime.snapshot(), cpuPercent: 0) },
                jobs: { try #require(runtime.snapshot().agent).jobs },
                restart: { actions.append("restart") },
                logs: {
                    actions.append("logs:" + $0); return ["first", "second"]
                },
                events: { try #require(runtime.snapshot().agent).events },
                run: {
                    actions.append("run:" + $0); _ = try await runtime.inspect()
                },
                cancel: {
                    actions.append("cancel:" + $0); runtime.cancel()
                }))
        #expect(
            try await cli.execute(["run", "storage.inspect"]).stdout == "queued storage.inspect\n")
        #expect(
            try await cli.execute(["cancel", "storage.inspect"]).stdout
                == "cancellation requested for storage.inspect\n")
        #expect(try await cli.execute(["restart"]).stdout == "background agent restarting\n")
        #expect(try await cli.execute(["logs", "--last", "10m"]).stdout == "first\nsecond\n")
        #expect(
            actions == ["run:storage.inspect", "cancel:storage.inspect", "restart", "logs:10m"])
        let snapshot = try await cli.execute(["--json"])
        let status = try JSONDecoder().decode(
            HostCoreAgentStatus.self, from: Data(snapshot.stdout.utf8))
        #expect(status.pid == getpid() && status.store.hasSuffix("/Core/agent.json"))
        let jobs = try await cli.execute(["jobs", "--json"])
        #expect(jobs.stdout.contains("\"runCount\": 1"))
        #expect(jobs.stdout.contains("\"ambientSeconds\": null"))
        #expect(jobs.stdout.hasPrefix("[\n  {\n"))
        #expect(try await cli.execute(["jobs"]).stdout.hasPrefix("ID"))
        let events = try await cli.execute(["events", "--json"])
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode([HostCoreAgentEvent].self, from: Data(events.stdout.utf8))
        #expect(decoded.last?.message == "Completed.")
        #expect(
            try await cli.execute(["events"]).stdout.contains("[info] storage.inspect: Completed."))
        await #expect(throws: HostCLIError.self) { try await cli.execute(["run"]) }
        await #expect(throws: HostCLIError.self) { try await cli.execute(["jobs", "extra"]) }
        await #expect(throws: HostCLIError.self) {
            try await cli.execute(["logs", "--last", "-1h"])
        }
        await #expect(throws: HostCLIError.self) {
            try await cli.execute(["status", "--json", "--json"])
        }
        #expect(actions.count == 4)
        await runtime.shutdown()
    }

    @Test func unavailableMutationsNeverEmitSuccess() async throws {
        let failure = HostCoreCommandFailure(
            "background agent", hint: "No owned core process is running.")
        let cli = HostCoreAgentCLI(
            backend: HostCoreAgentCLIBackend(
                status: { throw failure }, jobs: { throw failure }, restart: { throw failure },
                logs: { _ in throw failure }, events: { throw failure },
                run: { _ in throw failure }, cancel: { _ in throw failure }))
        for arguments in [
            ["status"], ["jobs"], ["restart", "--json"], ["run", "usage.refresh", "--json"],
            ["cancel", "usage.refresh"], ["logs"], ["events"],
        ] {
            let reply = try await cli.execute(arguments)
            #expect(reply.stdout.isEmpty && reply.exitCode == 4)
            #expect(
                reply.stderr == "error: background agent\nhint: No owned core process is running.\n"
            )
        }
    }

    @Test func cancellationDoesNotAcknowledgeAnUnqueuedOperation() async throws {
        var cancelled = false
        let cli = HostCoreAgentCLI(
            backend: HostCoreAgentCLIBackend(
                status: { throw HostCLIError.unavailable }, jobs: { [] }, restart: {},
                logs: { _ in [] }, events: { [] },
                run: { _ in
                    do { try await Task.sleep(for: .seconds(30)) } catch {
                        cancelled = true; throw error
                    }
                }, cancel: { _ in }))
        let task = Task { try await cli.execute(["run", "synthetic", "--json"]) }
        await Task.yield(); task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(cancelled)
        #expect(try await cli.execute(["logs"]).stdout.isEmpty)
    }
}
