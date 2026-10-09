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

    @Test func workerAppearanceUsesTheHostPreferencesAndClampsZoom() throws {
        let identifier = "com.pulkit.edith.tests.appearance-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: identifier))
        defer { defaults.removePersistentDomain(forName: identifier) }
        defaults.set("blue", forKey: "theme")
        defaults.set("dark", forKey: "appearance")
        defaults.set(2.0, forKey: "mainWindowZoom")
        let identity = try HostIdentity(
            identifier: identifier, supportDirectory: URL(fileURLWithPath: "/synthetic/support"))
        let configuration = HostWorkerConfiguration(
            identity: identity, extensionID: "sample", version: "1.0.0")
        #expect(configuration.theme == "blue")
        #expect(configuration.appearance == "dark")
        #expect(configuration.zoom == 1.6)
        defaults.set(Double.nan, forKey: "mainWindowZoom")
        #expect(
            HostWorkerConfiguration(identity: identity, extensionID: "sample", version: "1.0.0")
                .zoom == 1)
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

    @Test func disablingAWorkerAlsoStopsItsOwnedChildProcesses() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let identity = try HostIdentity(
            identifier: "com.pulkit.edith.tests.children",
            supportDirectory: URL(fileURLWithPath: "/synthetic/support"))
        let script = try #require(
            Bundle.module.url(forResource: "worker", withExtension: "py", subdirectory: "Fixtures"))
        let worker = HostWorker(
            configuration: HostWorkerConfiguration(
                identity: identity, extensionID: "sample", version: "1.0.0"),
            executable: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: [script.path, "child", file.path], requestTimeout: .seconds(2))
        try await worker.start()
        let childPID = try #require(Int32(String(contentsOf: file, encoding: .utf8)))
        #expect(kill(childPID, 0) == 0)
        try await worker.stop()
        let deadline = ContinuousClock.now + .seconds(2)
        while kill(childPID, 0) == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(kill(childPID, 0) == -1)
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
