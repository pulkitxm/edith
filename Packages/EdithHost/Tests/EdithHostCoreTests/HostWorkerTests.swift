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

    @Test(arguments: [
        "child", "child-group", "child-reserved", "child-group-crash", "child-group-ignore-stop",
    ])
    func disablingAWorkerAlsoStopsItsOwnedChildProcesses(mode: String) async throws {
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
            arguments: [script.path, mode, file.path], requestTimeout: .seconds(2))
        do {
            try await worker.start()
            #expect(mode != "child-group-crash")
        } catch {
            #expect(mode == "child-group-crash")
        }
        let childPID = try #require(Int32(String(contentsOf: file, encoding: .utf8)))
        if mode != "child-group-crash" { #expect(kill(childPID, 0) == 0) }
        try await worker.stop()
        let deadline = ContinuousClock.now + .seconds(2)
        while kill(childPID, 0) == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(kill(childPID, 0) == -1)
    }

    @Test func rejectedRestorationKeepsTheWorkerUsableUntilRetry() async throws {
        let worker = try fixture("reject-disable-once")
        try await worker.start()
        let pid = try #require(worker.processIdentifier)
        await #expect(
            throws: HostWorkerError.disableRejected("Restore sleep settings and try again.")
        ) { try await worker.stop() }
        #expect(worker.ready)
        #expect(worker.processIdentifier == pid)
        #expect(try await worker.status().ok)
        try await worker.stop()
        #expect(kill(pid, 0) == -1)
    }

    @Test func restorationCancellationAndItsLateReplyDoNotKillTheWorker() async throws {
        let worker = try fixture("late-disable")
        try await worker.start()
        let pid = try #require(worker.processIdentifier)
        let task = Task { try await worker.stop() }
        try await Task.sleep(for: .milliseconds(40))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(worker.ready)
        #expect(worker.processIdentifier == pid)
        try await Task.sleep(for: .milliseconds(350))
        #expect(try await worker.status().ok)
        try await worker.stop()
        #expect(kill(pid, 0) == -1)
    }

    @Test func restorationTimeoutPreservesTheWorkerAndAcceptsTheLateReply() async throws {
        let worker = try fixture("late-disable")
        try await worker.start()
        let pid = try #require(worker.processIdentifier)
        await #expect(throws: HostWorkerError.timedOut) {
            try await worker.prepareDisable(timeout: .milliseconds(120))
        }
        #expect(worker.ready)
        #expect(worker.processIdentifier == pid)
        try await Task.sleep(for: .milliseconds(300))
        #expect(try await worker.status().ok)
        try await worker.stop()
        #expect(kill(pid, 0) == -1)
    }

    @Test func ownedNavigationIsDeliveredOnlyAfterStart() async throws {
        let worker = try fixture("navigation")
        var received = 0
        worker.didRequestNavigation = { _ in received += 1 }
        try await worker.start()
        try await worker.show()
        try await worker.synchronize()
        #expect(received == 1)
        try await worker.stop()
    }

    @Test func earlyNavigationDoesNotEnterHostRouting() async throws {
        let worker = try fixture("navigation-early")
        var received = 0
        worker.didRequestNavigation = { _ in received += 1 }
        try await worker.start()
        try await worker.synchronize()
        #expect(received == 0)
        try await worker.stop()
    }

    @Test func recoveryNavigationCannotOpenHostContent() async throws {
        let worker = try fixture("navigation")
        var received = 0
        worker.didRequestNavigation = { _ in received += 1 }
        try await worker.start(recoveryOnly: true)
        try await worker.show()
        try await worker.synchronize()
        #expect(received == 0)
        try await worker.stop()
    }

    @Test func disablePreparationNavigationCannotOpenHostContent() async throws {
        let worker = try fixture("navigation-disable")
        var received = 0
        worker.didRequestNavigation = { _ in received += 1 }
        try await worker.start()
        try await worker.prepareDisable()
        #expect(received == 0)
        try await worker.stop()
    }

    @Test(arguments: ["navigation-wrong-id", "navigation-wrong-version"])
    func forgedNavigationTerminatesTheOwnedWorker(mode: String) async throws {
        let worker = try fixture(mode)
        var received = 0
        worker.didRequestNavigation = { _ in received += 1 }
        try await worker.start()
        do { try await worker.show(); try await worker.synchronize() } catch {}
        let deadline = ContinuousClock.now + .seconds(2)
        while worker.ready, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(received == 0)
        #expect(!worker.ready)
        try await worker.stop()
    }

    @Test func navigationAcknowledgesOnlyAfterTheOwningReceiverAppliesTheRoute() async throws {
        let worker = try fixture("navigation-ack")
        var applied = false
        worker.didRequestNavigation = { request in
            #expect(request.extensionID == "sample")
            try await Task.sleep(for: .milliseconds(60))
            applied = true
        }
        try await worker.start()
        try await worker.show()
        #expect(applied)
        #expect(worker.ready)
        try await worker.stop()
    }

    @Test func rejectedNavigationIsAcknowledgedWithoutKillingTheWorker() async throws {
        let worker = try fixture("navigation-rejected")
        worker.didRequestNavigation = { _ in throw HostWorkerError.rejected }
        try await worker.start()
        await #expect(throws: HostWorkerError.rejected) { try await worker.show() }
        #expect(worker.ready)
        #expect(try await worker.status().ok)
        try await worker.stop()
    }

    @Test(arguments: ["navigation-cancel", "navigation-disconnect"])
    func cancelledNavigationCannotApplyALateRoute(mode: String) async throws {
        let worker = try fixture(mode)
        var applied = false
        worker.didRequestNavigation = { _ in
            try await Task.sleep(for: .milliseconds(120))
            applied = true
        }
        try await worker.start()
        do { try await worker.show() } catch {}
        try await Task.sleep(for: .milliseconds(180))
        #expect(!applied)
        try await worker.stop()
    }

    @Test(arguments: HostWorkerStopReason.allCases)
    func closedStopReasonSelectsQuitOnlyForOriginalLidAwake(reason: HostWorkerStopReason)
        async throws
    {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let identity = try HostIdentity(
            identifier: "com.pulkit.edith.tests.quit-" + UUID().uuidString,
            supportDirectory: URL(fileURLWithPath: "/synthetic/support"))
        let script = try #require(
            Bundle.module.url(forResource: "worker", withExtension: "py", subdirectory: "Fixtures"))
        let worker = HostWorker(
            configuration: .init(identity: identity, extensionID: "lidAwake", version: "1.0.0"),
            executable: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: [script.path, "quit-policy", file.path], requestTimeout: .seconds(2))
        try await worker.start()
        let pid = try #require(worker.processIdentifier)
        try await worker.stop(reason: reason)
        let requests = try String(contentsOf: file, encoding: .utf8).split(separator: "\n").map {
            try JSONDecoder().decode(HostWorkerRequest.self, from: Data($0.utf8))
        }
        #expect(
            requests.map(\.operation) == [
                reason == .applicationQuit ? "prepareApplicationQuit" : "prepareDisable", "stop",
            ])
        #expect(requests.last?.stopReason == reason)
        #expect(kill(pid, 0) == -1)
    }

    @Test func unknownStopReasonIsRejectedByDecoding() {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(
                HostWorkerRequest.self,
                from: Data(
                    "{\"token\":\"\(UUID().uuidString)\",\"operation\":\"stop\",\"stopReason\":\"skipCleanup\"}"
                        .utf8))
        }
    }

    private func fixture(_ mode: String, timeout: Duration = .seconds(2)) throws -> HostWorker {
        let identity = try HostIdentity(
            identifier: "com.pulkit.edith.tests.workers",
            supportDirectory: URL(fileURLWithPath: "/synthetic/support"))
        let script = try #require(
            Bundle.module.url(forResource: "worker", withExtension: "py", subdirectory: "Fixtures"))
        return HostWorker(
            configuration: HostWorkerConfiguration(
                identity: identity, extensionID: "sample", version: "1.0.0"),
            executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: [script.path, mode],
            requestTimeout: timeout)
    }
}
