import Darwin
import EdithExtensionSupport
import Foundation
import Testing

@testable import EdithHostCore

@Suite @MainActor struct HostPrivilegedProcessTests {
    @Test func disablingOnePrivilegedWorkerReleasesItsProcessAndKeepsTheOtherAlive() async throws {
        let first = try fixture("normal")
        let second = try fixture("normal")
        try await first.start(); try await second.start()
        let firstPID = try #require(first.processIdentifier)
        let secondPID = try #require(second.processIdentifier)
        #expect(firstPID != secondPID)
        let bytes = Data("synthetic".utf8)
        #expect(try await first.invoke("read", payload: bytes) == bytes)
        try await first.stop()
        #expect(first.processIdentifier == nil)
        #expect(kill(firstPID, 0) == -1)
        #expect(second.processIdentifier == secondPID)
        #expect(try await second.invoke("read", payload: bytes) == bytes)
        try await second.stop()
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

    @Test func restoredWorkerMayExitCleanlyBeforeDeliveringItsStopResponse() async throws {
        let worker = try fixture("stop-without-response")
        try await worker.start()
        let pid = try #require(worker.processIdentifier)
        try await worker.stop()
        #expect(worker.processIdentifier == nil)
        #expect(kill(pid, 0) == -1)
    }

    @Test(arguments: ["prepare-without-response", "stop-failure"])
    func incompleteOrFailedRestorationIsNotReportedAsSuccessful(mode: String) async throws {
        let worker = try fixture(mode)
        try await worker.start()
        let pid = try #require(worker.processIdentifier)
        await #expect(throws: HostWorkerError.exited) { try await worker.stop() }
        #expect(worker.processIdentifier == nil)
        #expect(kill(pid, 0) == -1)
    }

    @Test func confirmedQuitFreesOnlyItsExactWorkerWithoutSendingDisable() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let worker = try fixture("normal", recording: file)
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
    }

    @Test func unacknowledgedQuitCannotCountAsSuccessfulRetention() async throws {
        let worker = try fixture("stop-without-response")
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

    private func fixture(_ mode: String, recording: URL? = nil) throws -> HostPrivilegedProcess {
        let script = try #require(
            Bundle.module.url(
                forResource: "privileged-worker", withExtension: "py", subdirectory: "Fixtures"))
        return HostPrivilegedProcess(
            executable: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: [script.path, mode] + (recording.map { [$0.path] } ?? []),
            timeout: .seconds(3))
    }
}
