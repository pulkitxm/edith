import EdithExtensionSupport
import Foundation
import Testing

@testable import EdithHostCore

@Suite struct HostAgentCommandServiceTests {
    private func root() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "core-commands-\(UUID().uuidString)")
    }

    private func finished(_ id: UUID, service: HostAgentCommandService) async throws
        -> HostAgentTaskStatus
    {
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        let payload = try HostAgentPayload.encode(HostAgentTaskIDRequest(id: id))
        while true {
            let value = try HostAgentPayload.decode(
                HostAgentTaskStatus.self, from: await service.execute(.status, payload: payload))
            if value.snapshot.state.isTerminal { return value }
            try #require(ContinuousClock.now < deadline)
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test func closedOperationsPreserveRealCommandInputEnvironmentWorkingDirectoryAndExitStatus()
        async throws
    {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = try HostAgentCommandService(directory: directory, environment: { [:] })
        await #expect(throws: HostAgentCommandError.self) { try await service.execute(.list) }
        try await service.start()
        let command = CLICommandRequest(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: [
                "-c",
                "read value; printf '%s:%s\\n' \"$value\" \"$FIXTURE_VALUE\"; pwd; printf 'cwd-fixture' > context-owned; printf 'stderr-fixture\\n' >&2; exit 9",
            ],
            environment: ["FIXTURE_VALUE": "owned"], currentDirectoryURL: directory, timeout: 2,
            standardInputData: Data("stdin-fixture\n".utf8))
        let submission = HostAgentTaskSubmission(
            operation: HostAgentTaskOperation.command, title: "Core fixture",
            payload: try HostAgentPayload.encode(command))
        let submitted = try HostAgentPayload.decode(
            HostAgentTaskSnapshot.self,
            from: await service.execute(.submit, payload: HostAgentPayload.encode(submission)))
        let duplicate = try HostAgentPayload.decode(
            HostAgentTaskSnapshot.self,
            from: await service.execute(.submit, payload: HostAgentPayload.encode(submission)))
        #expect(duplicate.id == submitted.id)
        let status = try await finished(submitted.id, service: service)
        let result = try HostAgentPayload.decode(
            CLICommandResult.self, from: #require(status.result))
        #expect(status.snapshot.failureCode == "commandExit")
        #expect(result.terminationStatus == 9)
        #expect(result.standardOutput.hasPrefix("stdin-fixture:owned\n"))
        #expect(
            try String(
                contentsOf: directory.appendingPathComponent("context-owned"), encoding: .utf8)
                == "cwd-fixture")
        #expect(result.standardError == "stderr-fixture\n")
        let list = try HostAgentPayload.decode(
            [HostAgentTaskSnapshot].self, from: await service.execute(.list))
        #expect(list.map(\.id) == [submitted.id])
        let forbidden = HostAgentTaskSubmission(
            operation: "feature.fake", title: "Rejected", payload: Data())
        await #expect(throws: HostAgentCommandError.self) {
            try await service.execute(.submit, payload: HostAgentPayload.encode(forbidden))
        }
        await #expect(throws: HostAgentCommandError.self) {
            try await service.execute(
                .list, payload: Data(count: HostAgentCommandService.maximumRequestBytes + 1))
        }
        #expect(HostAgentCommandOperation(rawValue: "feature.fake") == nil)
        await service.shutdown()
        await #expect(throws: HostAgentCommandError.self) { try await service.execute(.list) }
    }

    @Test func stopDrainsAnActualCommandAndItsDescendantBeforeReturning() async throws {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = try HostAgentCommandService(directory: directory, environment: { [:] })
        try await service.start()
        let request = CLICommandRequest(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf 'started\\n'; sleep 1; touch escaped"],
            environment: ["PATH": "/bin:/usr/bin"], currentDirectoryURL: directory, timeout: 3)
        let submission = HostAgentTaskSubmission(
            operation: HostAgentTaskOperation.command, title: "Drain fixture",
            payload: try HostAgentPayload.encode(request))
        _ = try await service.execute(.submit, payload: HostAgentPayload.encode(submission))
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while try await !service.tasks.status(submission.id).output.contains(where: {
            $0.text == "started"
        }), ContinuousClock.now < deadline { await Task.yield() }
        try #require(
            try await service.tasks.status(submission.id).output.contains { $0.text == "started" })
        await service.shutdown()
        #expect(try await service.tasks.status(submission.id).snapshot.state == .interrupted)
        try await Task.sleep(for: .milliseconds(1100))
        #expect(
            !FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("escaped").path))
        let restored = try HostAgentCommandService(directory: directory, environment: { [:] })
        try await restored.start()
        #expect(try await restored.tasks.status(submission.id).snapshot.state == .interrupted)
        await restored.shutdown()
    }

    @Test func scheduledDefinitionsAndDisabledStatePersistThroughTheFixedJSONOperations()
        async throws
    {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = try HostAgentCommandService(directory: directory, environment: { [:] })
        try await service.start()
        let definition = try HostScheduledTaskDefinition(
            name: "fixture-job", schedule: .interval(seconds: 300), executablePath: "/bin/echo",
            arguments: ["scheduled-fixture"], workingDirectory: directory.path)
        _ = try await service.execute(.scheduleAdd, payload: HostAgentPayload.encode(definition))
        let disabled = try HostAgentPayload.decode(
            HostScheduledTaskSnapshot.self,
            from: await service.execute(
                .scheduleEnabled,
                payload: HostAgentPayload.encode(
                    HostAgentScheduleEnabledRequest(name: definition.name, enabled: false))))
        #expect(!disabled.enabled)
        let task = try HostAgentPayload.decode(
            HostAgentTaskSnapshot.self,
            from: await service.execute(
                .scheduleRun,
                payload: HostAgentPayload.encode(
                    HostAgentScheduleNameRequest(name: definition.name))))
        let result = try HostAgentPayload.decode(
            CLICommandResult.self,
            from: #require(try await finished(task.id, service: service).result))
        #expect(result.standardOutput == "scheduled-fixture\n")
        await service.shutdown()
        let restored = try HostAgentCommandService(directory: directory, environment: { [:] })
        try await restored.start()
        let list = try HostAgentPayload.decode(
            [HostScheduledTaskSnapshot].self, from: await restored.execute(.scheduleList))
        #expect(list.count == 1)
        #expect(list.first?.enabled == false)
        #expect(list.first?.nextRunAt == nil)
        #expect(list.first?.lastTaskID == task.id)
        #expect(list.first?.lastState == .succeeded)
        _ = try await restored.execute(
            .scheduleRemove,
            payload: HostAgentPayload.encode(HostAgentScheduleNameRequest(name: definition.name)))
        #expect(
            try HostAgentPayload.decode(
                [HostScheduledTaskSnapshot].self, from: await restored.execute(.scheduleList)
            ).isEmpty)
        await restored.shutdown()
    }

    @Test func decodedDefinitionsCannotBypassConstructorValidation() async throws {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = try HostAgentCommandService(directory: directory, environment: { [:] })
        try await service.start()
        let definition = try HostScheduledTaskDefinition(
            name: "fixture-job", schedule: .interval(seconds: 300), executablePath: "/bin/echo",
            arguments: [])
        let encoded = try HostAgentPayload.encode(definition)
        var document = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        document["executablePath"] = "relative"
        await #expect(throws: HostAgentCommandError.self) {
            try await service.execute(
                .scheduleAdd, payload: JSONSerialization.data(withJSONObject: document))
        }
        document["executablePath"] = "/bin/echo"
        document["schedule"] = ["interval": ["seconds": 1]]
        await #expect(throws: HostAgentCommandError.self) {
            try await service.execute(
                .scheduleAdd, payload: JSONSerialization.data(withJSONObject: document))
        }
        #expect(
            try HostAgentPayload.decode(
                [HostScheduledTaskSnapshot].self, from: await service.execute(.scheduleList)
            ).isEmpty)
        await service.shutdown()
    }
}
