import Foundation
import Testing

@testable import EdithAgent
@testable import EdithKit

@Suite struct AgentTaskServiceTests {
    @Test func duplicateSubmissionsExecuteOnceAndConflictingPayloadsAreRejected() async throws {
        let service = try AgentTaskService(directory: nil)
        let calls = TaskTestCounter()
        await service.register(operation: "fixture") { payload, _ in
            await calls.increment()
            return payload
        }
        let request = submission("first")
        _ = try await service.submit(request)
        _ = try await service.submit(request)
        let result = try await finished(request.id, service: service)
        #expect(result.snapshot.state == .succeeded)
        #expect(result.result == request.payload)
        #expect(await calls.value == 1)
        let conflict = AgentTaskSubmission(
            id: request.id, operation: request.operation, title: request.title,
            payload: Data("second".utf8))
        await #expect(throws: AgentError.self) { _ = try await service.submit(conflict) }
    }

    @Test func concurrencyIsBoundedAndQueuedTasksStartInSubmissionOrder() async throws {
        let service = try AgentTaskService(directory: nil, limits: AgentTaskLimits(concurrency: 2))
        let gate = TaskTestGate()
        await service.register(operation: "fixture") { payload, _ in
            let number = Int(String(decoding: payload, as: UTF8.self))!
            await gate.enter(number)
            return payload
        }
        let requests = (0..<5).map { submission("\($0)") }
        for request in requests { _ = try await service.submit(request) }
        try await eventually { await gate.started.count == 2 }
        #expect(Set(await gate.started) == [0, 1])
        await gate.release(0)
        try await eventually { await gate.started.contains(2) }
        await gate.release(1)
        try await eventually { await gate.started.contains(3) }
        await gate.release(2)
        try await eventually { await gate.started.contains(4) }
        await gate.release(3)
        await gate.release(4)
        for request in requests { _ = try await finished(request.id, service: service) }
        #expect(await gate.maximumActive == 2)
        #expect(Array(await gate.started.suffix(3)) == [2, 3, 4])
    }

    @Test func queueAndPayloadLimitsRejectExcessWork() async throws {
        let service = try AgentTaskService(
            directory: nil,
            limits: AgentTaskLimits(
                concurrency: 1, queued: 1, payloadBytes: 8, queuedPayloadBytes: 8))
        let gate = TaskTestGate()
        await service.register(operation: "fixture") { payload, _ in
            await gate.enter(Int(String(decoding: payload, as: UTF8.self))!)
            return payload
        }
        let first = submission("1")
        let second = submission("2")
        _ = try await service.submit(first)
        _ = try await service.submit(second)
        await #expect(throws: AgentError.self) { _ = try await service.submit(submission("3")) }
        await #expect(throws: AgentError.self) {
            _ = try await service.submit(submission(String(repeating: "x", count: 9)))
        }
        _ = try await service.cancel(second.id)
        try await eventually { await gate.started == [1] }
        await gate.release(1)
        _ = try await finished(first.id, service: service)
        #expect(try await service.status(second.id).snapshot.state == .cancelled)
        #expect(await gate.started == [1])
    }

    @Test func runningCancellationKeepsItsWorkerSlotUntilExecutionStops() async throws {
        let events = TaskTestEvents()
        let service = try AgentTaskService(
            directory: nil, limits: AgentTaskLimits(concurrency: 1),
            record: { await events.append($0) })
        let gate = TaskTestGate()
        await service.register(operation: "fixture") { payload, _ in
            await gate.enter(Int(String(decoding: payload, as: UTF8.self))!)
            return payload
        }
        let first = submission("1")
        let second = submission("2")
        _ = try await service.submit(first)
        _ = try await service.submit(second)
        try await eventually { await gate.started == [1] }
        #expect(try await service.cancel(first.id).state == .cancelling)
        #expect(try await service.status(second.id).snapshot.state == .queued)
        try await eventually { await events.contains("task.cancelling", taskID: first.id) }
        #expect(await !events.contains("task.cancelled", taskID: first.id))
        await gate.release(1)
        #expect(try await finished(first.id, service: service).snapshot.state == .cancelled)
        try await eventually { await events.contains("task.cancelled", taskID: first.id) }
        try await eventually { await gate.started == [1, 2] }
        await gate.release(2)
        _ = try await finished(second.id, service: service)
    }

    @Test func cancellationBeforeSubmissionPreventsDelayedSideEffects() async throws {
        let service = try AgentTaskService(directory: nil)
        let calls = TaskTestCounter()
        await service.register(operation: "fixture") { _, _ in
            await calls.increment()
            return Data()
        }
        let request = submission("cancelled")
        #expect(try await service.cancel(request.id).state == .cancelled)
        #expect(try await service.submit(request).state == .cancelled)
        #expect(await calls.value == 0)
    }

    @Test func restartMarksUnfinishedTasksInterruptedWithoutPersistingRequestSecrets() async throws
    {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = try AgentTaskService(
            directory: directory, limits: AgentTaskLimits(concurrency: 1))
        let gate = TaskTestGate()
        await service.register(operation: "fixture") { _, _ in
            await gate.enter(1)
            return Data()
        }
        let first = submission("sensitive-request-environment")
        let second = submission("queued-request-secret")
        _ = try await service.submit(first)
        _ = try await service.submit(second)
        try await eventually { await gate.started == [1] }
        for file in try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)
        {
            let text = try String(contentsOf: file, encoding: .utf8)
            #expect(!text.contains("sensitive-request-environment"))
            #expect(!text.contains("queued-request-secret"))
            #expect(!text.contains(first.payload.base64EncodedString()))
        }
        let restored = try AgentTaskService(directory: directory)
        #expect(try await restored.status(first.id).snapshot.state == .interrupted)
        #expect(try await restored.status(second.id).snapshot.state == .interrupted)
        #expect(try await restored.submit(first).state == .interrupted)
        _ = try await service.cancel(first.id)
        _ = try await service.cancel(second.id)
        await gate.release(1)
        _ = try await finished(first.id, service: service)
    }

    @Test func completedResultsSurviveRestartAndHistoryStaysBounded() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let limits = AgentTaskLimits(retained: 3, resultBytes: 8, retainedResultBytes: 8)
        let service = try AgentTaskService(directory: directory, limits: limits)
        await service.register(operation: "fixture") { payload, _ in payload }
        var newest: UUID?
        for number in 0..<5 {
            let request = submission("v\(number)")
            _ = try await service.submit(request)
            _ = try await finished(request.id, service: service)
            newest = request.id
        }
        #expect(await service.snapshots().count == 3)
        let restored = try AgentTaskService(directory: directory, limits: limits)
        #expect(await restored.snapshots().count == 3)
        #expect(try await restored.status(newest!).result == Data("v4".utf8))
    }

    @Test func progressAndOversizedResultsHaveFixedBounds() async throws {
        let service = try AgentTaskService(directory: nil, limits: AgentTaskLimits(resultBytes: 4))
        await service.register(operation: "fixture") { _, context in
            for index in 0..<10_000 {
                context.report("\(index) " + String(repeating: "x", count: 2_000))
            }
            return Data(repeating: 1, count: 5)
        }
        let request = submission("progress")
        _ = try await service.submit(request)
        let status = try await finished(request.id, service: service)
        #expect(status.output.count == 128)
        #expect(status.output.last?.sequence == 10_000)
        #expect(status.output.allSatisfy { $0.text.count <= 1_000 })
        #expect(status.snapshot.state == .failed)
        #expect(status.snapshot.failureCode == "outputLimitExceeded")
        #expect(status.result == nil)
    }

    @Test func commandJobsExecuteRealProcessesWithSeparatedOutputAndInput() async throws {
        let service = try AgentTaskService(directory: nil)
        await service.registerCommand()
        let request = CLICommandRequest(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: [
                "-c", "read value; printf '%s\\n' \"$value\"; printf 'diagnostic\\n' >&2; exit 7",
            ],
            environment: [:], timeout: 2, maximumOutputBytes: 1_024,
            standardInputData: Data("fixture-input\n".utf8))
        let task = AgentTaskSubmission(
            operation: AgentTaskOperation.command, title: "Fixture process",
            payload: try AgentPayload.encode(request))
        _ = try await service.submit(task)
        let status = try await finished(task.id, service: service)
        let result = try AgentPayload.decode(CLICommandResult.self, from: #require(status.result))
        #expect(status.snapshot.state == .failed)
        #expect(status.snapshot.failureCode == "commandExit")
        #expect(result.terminationStatus == 7)
        #expect(result.standardOutput == "fixture-input\n")
        #expect(result.standardError == "diagnostic\n")
        #expect(
            status.output.contains { $0.stream == .standardOutput && $0.text == "fixture-input" })
        #expect(status.output.contains { $0.stream == .standardError && $0.text == "diagnostic" })
    }

    @Test func commandCancellationTerminatesItsProcessGroup() async throws {
        let service = try AgentTaskService(directory: nil)
        await service.registerCommand()
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let request = CLICommandRequest(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf 'started\\n'; sleep 1; touch escaped"], environment: [:],
            currentDirectoryURL: directory, timeout: 5)
        let task = AgentTaskSubmission(
            operation: AgentTaskOperation.command, title: "Cancellation fixture",
            payload: try AgentPayload.encode(request))
        _ = try await service.submit(task)
        try await eventually {
            (try? await service.status(task.id).output.contains { $0.text == "started" }) == true
        }
        _ = try await service.cancel(task.id)
        let cancelled = try await finished(task.id, service: service).snapshot
        #expect(cancelled.state == .cancelled)
        #expect(cancelled.failure == "Cancelled by request.")
        #expect(cancelled.failureCode == "cancelled")
        try await Task.sleep(for: .milliseconds(1_100))
        #expect(
            !FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("escaped").path))
    }

    @Test func commandTimeoutKeepsItsTypedFailure() async throws {
        let service = try AgentTaskService(directory: nil)
        await service.registerCommand()
        let request = CLICommandRequest(
            executableURL: URL(fileURLWithPath: "/bin/sleep"), arguments: ["5"], environment: [:],
            timeout: 0.02)
        let task = AgentTaskSubmission(
            operation: AgentTaskOperation.command, title: "Timeout fixture",
            payload: try AgentPayload.encode(request))
        _ = try await service.submit(task)
        let status = try await finished(task.id, service: service)
        #expect(status.snapshot.state == .failed)
        #expect(status.snapshot.failureCode == "timedOut")
    }

    private func submission(_ value: String) -> AgentTaskSubmission {
        AgentTaskSubmission(operation: "fixture", title: "Fixture task", payload: Data(value.utf8))
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "task-tests-\(UUID().uuidString)")
    }

    private func finished(_ id: UUID, service: AgentTaskService) async throws -> AgentTaskStatus {
        try await eventually { (try? await service.status(id).snapshot.state.isTerminal) == true }
        return try await service.status(id)
    }

    private func eventually(_ condition: @escaping @Sendable () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while !(await condition()), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await condition())
    }
}

private actor TaskTestCounter {
    var value = 0
    func increment() { value += 1 }
}

private actor TaskTestEvents {
    private var values: [AgentEvent] = []
    func append(_ event: AgentEvent) { values.append(event) }
    func contains(_ name: String, taskID: UUID) -> Bool {
        values.contains { $0.name == name && $0.taskID == taskID }
    }
}

private actor TaskTestGate {
    private var waiting: [Int: CheckedContinuation<Void, Never>] = [:]
    private var active = 0
    var started: [Int] = []
    var maximumActive = 0

    func enter(_ number: Int) async {
        started.append(number)
        active += 1
        maximumActive = max(maximumActive, active)
        await withCheckedContinuation { waiting[number] = $0 }
        active -= 1
    }

    func release(_ number: Int) { waiting.removeValue(forKey: number)?.resume() }
}
