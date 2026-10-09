import Darwin
import Foundation
import Testing

@testable import EdithHostCore

@Suite @MainActor struct HostWorkerTests {
    @Test func identitiesRoundTripWithoutCrossingNamespaces() throws {
        for identifier in [
            "com.pulkit.edith", "com.pulkit.edith.dev.sample", "com.pulkit.edith.tests.sample",
        ] {
            let identity = try HostIdentity(
                identifier: identifier, supportDirectory: URL(fileURLWithPath: "/synthetic/support")
            )
            let configuration = HostWorkerConfiguration(
                identity: identity, extensionID: "sample", version: "1.0.0")
            #expect(try configuration.identity().root == identity.root)
        }
    }

    @Test func partialAndMultipleFramesAreDecoded() throws {
        var frames = HostWorkerFrames()
        #expect(try frames.append(Data("first".utf8)).isEmpty)
        let decoded = try frames.append(Data("\nsecond\npartial".utf8))
        #expect(decoded.map { String(decoding: $0, as: UTF8.self) } == ["first", "second"])
        #expect(try frames.append(Data("\n".utf8)) == [Data("partial".utf8)])
    }

    @Test func excessiveAndEmptyFramesAreRejected() throws {
        var frames = HostWorkerFrames()
        #expect(throws: HostWorkerError.invalidResponse) {
            try frames.append(Data(repeating: 120, count: HostWorkerFrames.maximumBytes + 1))
        }
        var empty = HostWorkerFrames()
        #expect(throws: HostWorkerError.invalidResponse) { try empty.append(Data([10])) }
    }

    @Test func startShowAndStopReleaseTheProcess() async throws {
        let worker = try fixture("normal")
        try await worker.start()
        let pid = try #require(worker.processIdentifier)
        #expect(worker.ready)
        try await worker.show()
        try await worker.synchronize()
        #expect(try await worker.status().ok)
        try await worker.stop()
        #expect(!worker.ready)
        #expect(worker.processIdentifier == nil)
        #expect(kill(pid, 0) == -1)
    }

    @Test(arguments: ["crash", "timeout", "malformed", "reject", "wrong-version"])
    func failedStartsDoNotLeaveProcessesRunning(mode: String) async throws {
        let worker = try fixture(mode)
        do {
            try await worker.start()
            Issue.record("A failed worker was reported ready")
        } catch {
            #expect(!worker.ready)
            #expect(worker.processIdentifier == nil)
        }
        try await worker.stop()
    }

    @Test func disablingAnUnresponsiveWorkerKillsIt() async throws {
        let worker = try fixture("ignore-stop")
        try await worker.start()
        let pid = try #require(worker.processIdentifier)
        try await worker.stop()
        #expect(worker.processIdentifier == nil)
        #expect(kill(pid, 0) == -1)
    }

    private func fixture(_ mode: String) throws -> HostWorker {
        let identity = try HostIdentity(
            identifier: "com.pulkit.edith.tests.workers",
            supportDirectory: URL(fileURLWithPath: "/synthetic/support"))
        let script = try #require(
            Bundle.module.url(forResource: "worker", withExtension: "py", subdirectory: "Fixtures"))
        return HostWorker(
            configuration: HostWorkerConfiguration(
                identity: identity, extensionID: "sample", version: "1.0.0"),
            executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: [script.path, mode],
            requestTimeout: .seconds(2))
    }
}
