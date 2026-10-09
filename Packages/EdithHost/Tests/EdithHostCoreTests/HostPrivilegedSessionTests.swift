import Darwin
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

    private func activate(_ session: HostPrivilegedSession, _ source: URL) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            session.activate(source.path, owner: "sample", version: "1.0.0") {
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
        var workers: [HostPrivilegedProcess] = []
        var ended = false
        init(mode: String) throws {
            self.mode = mode
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appendingPathComponent("privilege-session-" + UUID().uuidString)
            bundle = root.appendingPathComponent("sample.bundle")
            let contents = bundle.appendingPathComponent("Contents")
            try FileManager.default.createDirectory(
                at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
            try FileManager.default.copyItem(
                at: URL(fileURLWithPath: "/usr/bin/true"),
                to: contents.appendingPathComponent("MacOS/Runtime"))
            let info: [String: Any] = [
                "CFBundleIdentifier": "com.pulkit.edith.extensions.sample.privileged",
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
                authorize: { _, _, _ in
                    guard authorized else { throw MarketplaceError.invalidSignature }
                }, reserveOwner: { [self] in leases.reserve($0) },
                releaseOwner: { [self] in leases.release($0) },
                makeWorker: { [self] _ in
                    let script = try #require(
                        Bundle.module.url(
                            forResource: "privileged-worker", withExtension: "py",
                            subdirectory: "Fixtures"))
                    let worker = HostPrivilegedProcess(
                        executable: URL(fileURLWithPath: "/usr/bin/python3"),
                        arguments: [script.path, mode], timeout: .seconds(3))
                    workers.append(worker); return worker
                }, ended: { [self] in ended = true })
        }
        func clean() { try? FileManager.default.removeItem(at: root) }
    }
}
