import Darwin
import EdithExtensionSupport
import ExtensionMarketplace
import Foundation
import Testing
@testable import EdithHostCore

@Suite @MainActor struct HostPrivilegedSessionTests {
    @Test func backgroundConnectionCallbacksBindOnTheMainActor() async {
        let main = await withCheckedContinuation {
            (continuation: CheckedContinuation<Bool, Never>) in
            Task.detached {
                let connection = NSXPCConnection(serviceName: "com.pulkit.edith.synthetic.fixture")
                HostPrivilegedCarrier.bindAcceptedConnection(
                    connection, requirement: "identifier \"synthetic\""
                ) { box in
                    let main = Thread.isMainThread
                    box.connection.invalidate()
                    continuation.resume(returning: main)
                }
            }
        }
        #expect(main)
    }

    @Test func unauthorizedCallersNeverReserveAnOwnerOrCopyTheirPayload() async throws {
        let fixture = try Fixture(mode: "normal")
        defer { fixture.clean() }
        let session = fixture.session(authorized: false)
        await #expect(throws: NSError.self) { try await activate(session, fixture.bundle) }
        #expect(fixture.workers.isEmpty)
        #expect(fixture.leases.reserve("sample"))
        #expect(!FileManager.default.fileExists(atPath: fixture.admission.root.path))
    }

    @Test func failedRestoreKeepsTheExclusiveLeaseUntilSuccess() async throws {
        let fixture = try Fixture(mode: "reject-once")
        defer { fixture.clean() }
        let session = fixture.session()
        try await activate(session, fixture.bundle)
        #expect(!fixture.leases.reserve("sample"))
        let pid = try #require(fixture.workers.first?.processIdentifier)
        await #expect(throws: NSError.self) { try await release(session) }
        #expect(kill(pid, 0) == 0 && !fixture.leases.reserve("sample"))
        try await release(session)
        #expect(fixture.ended && fixture.leases.reserve("sample"))
        #expect(kill(pid, 0) == -1)
    }

    @Test func anUnexpectedPrivilegedExitRestartsTheSealedPayloadToRestoreItsJournal() async throws
    {
        let fixture = try Fixture(mode: "normal")
        defer { fixture.clean() }
        let session = fixture.session()
        try await activate(session, fixture.bundle)
        let pid = try #require(fixture.workers.first?.processIdentifier)
        #expect(kill(pid, SIGKILL) == 0)
        let deadline = ContinuousClock.now + .seconds(4)
        while !fixture.ended, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(fixture.ended && fixture.workers.count == 2)
        #expect(fixture.workers.allSatisfy { $0.processIdentifier == nil })
        #expect(fixture.leases.reserve("sample"))
    }

    @Test func authenticatedQuitReleasesLeaseAndConnectionLossCannotRestartFinishedWorker()
        async throws
    {
        let fixture = try Fixture(mode: "normal", owner: "lidAwake")
        defer { fixture.clean() }
        let session = fixture.session()
        try await activate(session, fixture.bundle, owner: fixture.owner)
        let pid = try #require(fixture.workers.first?.processIdentifier)
        _ = try await quit(session)
        #expect(fixture.ended && fixture.workers.count == 1)
        #expect(kill(pid, 0) == -1 && fixture.leases.reserve("lidAwake"))
        session.connectionLost()
        try await Task.sleep(for: .milliseconds(50))
        #expect(fixture.workers.count == 1)
        #expect(try fixture.operations() == ["start", "stop"])
    }

    @Test func anotherExtensionCannotClaimLidAwakeRetention() async throws {
        let fixture = try Fixture(mode: "normal")
        defer { fixture.clean() }
        let session = fixture.session()
        try await activate(session, fixture.bundle)
        await #expect(throws: NSError.self) { try await quit(session) }
        #expect(!fixture.ended && fixture.workers.first?.processIdentifier != nil)
        try await release(session)
        #expect(try fixture.operations() == ["start", "prepareDisable", "stop"])
    }

    @Test func changedCallerAuthorizationCannotRelinquishCurrentLease() async throws {
        let fixture = try Fixture(mode: "normal", owner: "lidAwake")
        defer { fixture.clean() }
        let session = fixture.session()
        try await activate(session, fixture.bundle, owner: fixture.owner)
        fixture.authorized = false
        await #expect(throws: NSError.self) { try await quit(session) }
        #expect(try fixture.operations() == ["start"])
        fixture.authorized = true
        try await release(session)
        #expect(fixture.ended)
    }

    @Test(arguments: ["stop-without-response", "late-stop", "stop-after-response-crash"])
    func lostAcknowledgementOrOwnerConnectionRestoresBeforeReleasingLease(mode: String) async throws
    {
        let fixture = try Fixture(mode: mode, owner: "lidAwake")
        defer { fixture.clean() }
        let session = fixture.session()
        try await activate(session, fixture.bundle, owner: fixture.owner)
        let quitting = Task { try await quit(session) }
        if mode == "late-stop" {
            try await Task.sleep(for: .milliseconds(50))
            session.connectionLost()
        }
        await #expect(throws: NSError.self) { try await quitting.value }
        let deadline = ContinuousClock.now + .seconds(8)
        while !fixture.ended, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(fixture.ended && fixture.workers.count == 2)
        #expect(fixture.workers.allSatisfy { $0.processIdentifier == nil })
        #expect(try fixture.operations() == ["start", "stop", "start", "prepareDisable", "stop"])
        #expect(fixture.leases.reserve("lidAwake"))
    }

    private func quit(_ session: HostPrivilegedSession) async throws -> Data {
        let policy = HostApplicationQuitPolicy(
            reason: .applicationQuit, restoreOnQuit: false,
            host: try #require(ExtensionProcessIdentity.current))
        let bytes = try JSONEncoder().encode(policy)
        return try await withCheckedThrowingContinuation { continuation in
            session.invoke(HostApplicationQuitPolicy.command, payload: bytes) { data, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: data ?? Data())
                }
            }
        }
    }

    private func activate(_ session: HostPrivilegedSession, _ source: URL, owner: String = "sample")
        async throws
    {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            session.activate(source.path, owner: owner, version: "1.0.0") {
                if let error = $0 {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }
    private func release(_ session: HostPrivilegedSession) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            session.release {
                if let error = $0 {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    @MainActor private final class Fixture {
        let root: URL
        let bundle: URL
        let admission: HostPrivilegedAdmission
        let leases = HostPrivilegedLeases()
        let mode: String
        let owner: String
        var authorized = true
        var workers: [HostPrivilegedProcess] = []
        var ended = false
        init(mode: String, owner: String = "sample") throws {
            self.mode = mode
            self.owner = owner
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appendingPathComponent("privilege-session-" + UUID().uuidString)
            bundle = root.appendingPathComponent(owner + ".bundle")
            let contents = bundle.appendingPathComponent("Contents")
            try FileManager.default.createDirectory(
                at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
            try FileManager.default.copyItem(
                at: URL(fileURLWithPath: "/usr/bin/true"),
                to: contents.appendingPathComponent("MacOS/Runtime"))
            let info: [String: Any] = [
                "CFBundleIdentifier": "com.pulkit.edith.extensions." + owner + ".privileged",
                "CFBundleExecutable": "Runtime", "CFBundleShortVersionString": "1.0.0",
                "EdithHostABI": MarketplaceConfiguration.workerHostABI,
            ]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                .write(to: contents.appendingPathComponent("Info.plist"))
            admission = .init(
                root: root.appendingPathComponent("Protected"), ownerUID: getuid(), verify: { _ in }
            )
        }
        func session(authorized: Bool = true) -> HostPrivilegedSession {
            HostPrivilegedSession(
                admission: admission,
                authorize: { [self] _, _, _ in
                    guard authorized && self.authorized else {
                        throw MarketplaceError.invalidSignature
                    }
                }, authorizeQuit: { policy in try policy.validate() },
                reserveOwner: { [self] in leases.reserve($0) },
                releaseOwner: { [self] in leases.release($0) },
                makeWorker: { [self] _ in
                    let script = try #require(
                        Bundle.module.url(
                            forResource: "privileged-worker", withExtension: "py",
                            subdirectory: "Fixtures"))
                    let worker = HostPrivilegedProcess(
                        executable: URL(fileURLWithPath: "/usr/bin/python3"),
                        arguments: [
                            script.path, mode, root.appendingPathComponent("requests.jsonl").path,
                        ], timeout: .seconds(3))
                    workers.append(worker); return worker
                }, ended: { [self] in ended = true })
        }
        func operations() throws -> [String] {
            try String(contentsOf: root.appendingPathComponent("requests.jsonl"), encoding: .utf8)
                .split(separator: "\n").map {
                    try JSONDecoder().decode(HostPrivilegedRequest.self, from: Data($0.utf8))
                        .operation
                }
        }
        func clean() { try? FileManager.default.removeItem(at: root) }
    }
}
