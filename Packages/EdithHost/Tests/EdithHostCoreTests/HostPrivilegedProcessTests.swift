import Darwin
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

    private func fixture(_ mode: String) throws -> HostPrivilegedProcess {
        let script = try #require(
            Bundle.module.url(
                forResource: "privileged-worker", withExtension: "py", subdirectory: "Fixtures"))
        return HostPrivilegedProcess(
            executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: [script.path, mode],
            timeout: .seconds(3))
    }
}
