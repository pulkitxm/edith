import Darwin
import EdithExtensionSupport
import Foundation
import Testing

@testable import EdithHostCore

@Suite @MainActor struct HostPrivilegedProcessTests {
    @Test func disablingOnePrivilegedWorkerReleasesItsProcessAndKeepsTheOtherAlive() async throws {
        let first = try fixture("normal")
        let second = try fixture("normal")
        try await stage("first worker start") { try await first.start() }
        try await stage("second worker start") { try await second.start() }
        let firstPID = try #require(first.processIdentifier)
        let secondPID = try #require(second.processIdentifier)
        #expect(firstPID != secondPID)
        let bytes = Data("synthetic".utf8)
        let firstRead = try await stage("first worker read") {
            try await first.invoke("read", payload: bytes)
        }
        #expect(firstRead == bytes)
        try await stage("first worker disable") { try await first.stop() }
        #expect(first.processIdentifier == nil)
        #expect(kill(firstPID, 0) == -1)
        #expect(second.processIdentifier == secondPID)
        let secondRead = try await stage("second worker read after first disable") {
            try await second.invoke("read", payload: bytes)
        }
        #expect(secondRead == bytes)
        try await stage("second worker disable") { try await second.stop() }
        #expect(kill(secondPID, 0) == -1)
    }

    @Test func failedPrivilegedRestorationPreservesTheProcessUntilRetry() async throws {
        let worker = try fixture("reject-once")
        try await worker.start()
        let pid = try #require(worker.processIdentifier)
        await #expect(throws: HostWorkerError.disableRejected("Restore refused")) {
            try await worker.stop()
        }
        #expect(worker.processIdentifier == pid)
        #expect(kill(pid, 0) == 0)
        #expect(try await worker.invoke("read", payload: Data()).isEmpty)
        try await worker.stop()
        #expect(kill(pid, 0) == -1)
    }

    @Test func cancellingPrivilegedRestorationDoesNotKillTheProcess() async throws {
        let worker = try fixture("late")
        try await worker.start()
        let pid = try #require(worker.processIdentifier)
        let stop = Task { try await worker.stop() }
        try await Task.sleep(for: .milliseconds(40)); stop.cancel()
        await #expect(throws: CancellationError.self) { try await stop.value }
        #expect(worker.processIdentifier == pid)
        try await Task.sleep(for: .milliseconds(350))
        #expect(try await worker.invoke("read", payload: Data()).isEmpty)
        try await worker.stop()
        #expect(kill(pid, 0) == -1)
    }

    @Test(arguments: ["stop-without-response", "stop-eof-before-exit"])
    func restoredWorkerMayExitCleanlyBeforeDeliveringItsStopResponse(mode: String) async throws {
        let worker = try fixture(mode)
        try await worker.start()
        let pid = try #require(worker.processIdentifier)
        try await worker.stop()
        #expect(worker.processIdentifier == nil)
        #expect(kill(pid, 0) == -1)
    }

    @Test(arguments: ["prepare-without-response", "stop-failure", "stop-eof-before-failure"])
    func incompleteOrFailedRestorationIsNotReportedAsSuccessful(mode: String) async throws {
        let worker = try fixture(mode)
        try await worker.start()
        let pid = try #require(worker.processIdentifier)
        await #expect(throws: HostWorkerError.exited) { try await worker.stop() }
        #expect(worker.processIdentifier == nil)
        #expect(kill(pid, 0) == -1)
    }

    @Test func outputClosureCannotNotifyExitOrAcknowledgeAnUnexpectedlyDeadWorker() async throws {
        let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("privileged-output-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let recording = directory.appendingPathComponent("requests.jsonl")
        let worker = try fixture("start-eof-until-release", recording: recording)
        var exits = 0
        worker.didExit = { exits += 1 }
        try await worker.start()
        let pid = try #require(worker.processIdentifier)
        let closedDeadline = ContinuousClock.now + .seconds(4)
        while !worker.outputClosed, ContinuousClock.now < closedDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(worker.outputClosed && kill(pid, 0) == 0 && exits == 0)
        await #expect(throws: HostWorkerError.exited) { try await worker.stop() }
        #expect(kill(pid, 0) == 0 && exits == 0)
        try Data().write(to: directory.appendingPathComponent("requests.jsonl.release"))
        let exitDeadline = ContinuousClock.now + .seconds(4)
        while exits == 0, ContinuousClock.now < exitDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(exits == 1 && worker.processIdentifier == nil && kill(pid, 0) == -1)
        await #expect(throws: HostWorkerError.exited) { try await worker.stop() }
        #expect(exits == 1)
    }

    @Test func confirmedQuitFreesOnlyItsExactWorkerWithoutSendingDisable() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let worker = try fixture("normal", recording: file)
        var exits = 0
        worker.didExit = { exits += 1 }
        try await worker.start()
        let pid = try #require(worker.processIdentifier)
        let host = try #require(ExtensionProcessIdentity.current)
        try await worker.stop(
            reason: .applicationQuit, owner: "lidAwake",
            quitPolicy: .init(reason: .applicationQuit, restoreOnQuit: false, host: host))
        let requests = try String(contentsOf: file, encoding: .utf8).split(separator: "\n").map {
            try JSONDecoder().decode(HostPrivilegedRequest.self, from: Data($0.utf8))
        }
        #expect(requests.map(\.operation) == ["start", "stop"])
        let stop = try #require(requests.last?.stop)
        #expect(stop.worker.pid == pid && stop.parent == host && stop.owner == "lidAwake")
        #expect(worker.processIdentifier == nil && kill(pid, 0) == -1)
        #expect(exits == 1)
        try await worker.stop()
        #expect(exits == 1)
    }

    @Test(arguments: [
        "stop-without-response", "stop-eof-before-exit", "stop-after-response-crash",
    ])
    func unacknowledgedOrCrashedQuitCannotCountAsSuccessfulRetention(mode: String) async throws {
        let worker = try fixture(mode)
        try await worker.start()
        let host = try #require(ExtensionProcessIdentity.current)
        await #expect(throws: HostWorkerError.exited) {
            try await worker.stop(
                reason: .applicationQuit, owner: "lidAwake",
                quitPolicy: .init(reason: .applicationQuit, restoreOnQuit: false, host: host))
        }
    }

    @Test(arguments: HostWorkerStopReason.allCases.filter { $0 != .applicationQuit })
    func everyForcedReasonRejectsRetentionAndLeavesWorkerRestorable(reason: HostWorkerStopReason)
        async throws
    {
        let worker = try fixture("normal")
        try await worker.start()
        let host = try #require(ExtensionProcessIdentity.current)
        await #expect(throws: HostWorkerError.rejected) {
            try await worker.stop(
                reason: reason, owner: "lidAwake",
                quitPolicy: .init(reason: .applicationQuit, restoreOnQuit: false, host: host))
        }
        #expect(worker.processIdentifier != nil)
        try await worker.stop(reason: reason)
        #expect(worker.processIdentifier == nil)
    }

    @Test func coldFixtureStartupUsesTheProductionRequestBudget() async throws {
        let worker = try fixture("delayed-start", startupDelay: 3.4)
        let started = ContinuousClock.now
        try await stage("delayed fixture start using production budget") {
            try await worker.start()
        }
        #expect(ContinuousClock.now - started >= .seconds(3.4))
        let pid = try #require(worker.processIdentifier)
        let bytes = Data("synthetic delayed startup".utf8)
        #expect(try await worker.invoke("read", payload: bytes) == bytes)
        try await worker.stop()
        #expect(worker.processIdentifier == nil && kill(pid, 0) == -1)
    }

    @Test func anUnresponsiveStartupStillFailsWithinItsExplicitBudgetAndExits() async throws {
        let worker = try fixture(
            "silent-start", startupDelay: 0.6, timeout: .milliseconds(150))
        let started = ContinuousClock.now
        await #expect(throws: HostWorkerError.timedOut) { try await worker.start() }
        #expect(ContinuousClock.now - started < .seconds(5))
        let pid = try #require(worker.processIdentifier)
        let deadline = ContinuousClock.now + .seconds(5)
        while worker.processIdentifier != nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(worker.processIdentifier == nil && kill(pid, 0) == -1)
    }

    private enum FixtureStageFailure: Error {
        case failed(String, String)
    }

    private func stage<T>(_ name: String, operation: () async throws -> T) async throws -> T {
        do { return try await operation() } catch {
            throw FixtureStageFailure.failed(name, String(describing: error))
        }
    }

    private func fixture(
        _ mode: String, recording: URL? = nil, startupDelay: TimeInterval = 0,
        timeout: Duration? = nil
    ) throws -> HostPrivilegedProcess {
        let script = try #require(
            Bundle.module.url(
                forResource: "privileged-worker", withExtension: "py", subdirectory: "Fixtures"))
        let executable = URL(fileURLWithPath: "/usr/bin/python3")
        let arguments = ["-I", script.path, mode, recording?.path ?? "", String(startupDelay)]
        if let timeout {
            return HostPrivilegedProcess(
                executable: executable, arguments: arguments, timeout: timeout)
        }
        return HostPrivilegedProcess(executable: executable, arguments: arguments)
    }
}
