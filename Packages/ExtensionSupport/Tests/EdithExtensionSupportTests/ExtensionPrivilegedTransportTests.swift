import Darwin
import Foundation
import Testing
@testable import EdithExtensionCore

@Suite @MainActor struct ExtensionPrivilegedTransportTests {
    @Test func aCarrierThatNeverAnswersTheStartIsNamedInTheError() async throws {
        let carrier = SyntheticCarrier(answersStart: false)
        let transport = carrier.transport()
        defer { transport.invalidate(); carrier.stop() }
        await #expect(throws: ExtensionPrivilegedError.noAnswer(.start, seconds: 1)) {
            try await transport.activate(
                source: URL(fileURLWithPath: "/synthetic/privileged.bundle"), owner: "sample",
                version: "1.0.0")
        }
        let message = ExtensionPrivilegedError.noAnswer(.start, seconds: 20).localizedDescription
        #expect(message.contains("within 20 seconds"))
        #expect(message.contains("start the privileged part of the extension"))
    }

    @Test func anUnansweredCommandNamesTheCommand() async throws {
        let carrier = SyntheticCarrier(answersStart: true)
        let transport = carrier.transport()
        defer { transport.invalidate(); carrier.stop() }
        try await transport.activate(
            source: URL(fileURLWithPath: "/synthetic/privileged.bundle"), owner: "sample",
            version: "1.0.0")
        await #expect(
            throws: ExtensionPrivilegedError.noAnswer(.command("setSleepDisabled"), seconds: 1)
        ) {
            try await transport.invoke("setSleepDisabled", payload: Data("true".utf8))
        }
        #expect(
            ExtensionPrivilegedError.noAnswer(.command("setSleepDisabled"), seconds: 20)
                .localizedDescription.contains("run the setSleepDisabled request"))
    }

    @Test func aRejectedConnectionFailsAtOnceAndSaysTheHelperClosedIt() async throws {
        let carrier = SyntheticCarrier(answersStart: true, rejects: true)
        let transport = carrier.transport()
        defer { transport.invalidate(); carrier.stop() }
        let started = ContinuousClock.now
        await #expect(throws: ExtensionPrivilegedError.closed(.start)) {
            try await transport.activate(
                source: URL(fileURLWithPath: "/synthetic/privileged.bundle"), owner: "sample",
                version: "1.0.0")
        }
        #expect(ContinuousClock.now - started < .milliseconds(900))
    }

    @Test func anUnansweredStartFromAnOutdatedCarrierAsksForARestart() async throws {
        for (failure, predates, mode, expected) in [
            (
                ExtensionPrivilegedError.noAnswer(.start, seconds: 20), true,
                ExtensionPrivilegedClient.Mode.managed, ExtensionPrivilegedError.outdatedCarrier
            ),
            (.closed(.start), true, .managed, .outdatedCarrier),
            (.noAnswer(.start, seconds: 20), false, .managed, .noAnswer(.start, seconds: 20)),
            (.closed(.release), true, .managed, .closed(.release)),
            (
                .noAnswer(.start, seconds: 20), true,
                .connectOnly(hostIdentifier: "com.example.host"), .noAnswer(.start, seconds: 20)
            ),
        ] {
            var checks = 0
            let client = ExtensionPrivilegedClient(
                owner: "sample", source: URL(fileURLWithPath: "/synthetic/payload.bundle"),
                version: "1.0.0", mode: mode, status: { .enabled },
                carrierPredatesHost: {
                    checks += 1; return predates
                },
                connect: { FailingStartTransport(failure: failure, invalidated: $0) })
            await #expect(throws: expected) {
                try await client.invoke("setSleepDisabled", payload: Data())
            }
            #expect(checks == (mode == .managed && failure != .closed(.release) ? 1 : 0))
        }
        #expect(
            ExtensionPrivilegedError.outdatedCarrier.localizedDescription.contains(
                "Restart the Mac once"))
    }

    @Test func carrierProcessesStartedBeforeTheInstalledExecutableAreOutdated() throws {
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        #expect(proc_pidpath(getpid(), &path, UInt32(path.count)) > 0)
        let name = URL(fileURLWithPath: String(cString: path)).lastPathComponent
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("carrier-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let installed = root.appendingPathComponent(name)
        #expect(
            !ExtensionPrivilegedCarrierProcess.startTimes(
                named: name, user: getuid(), parent: getppid()
            ).isEmpty)
        try FileManager.default.createSymbolicLink(
            at: installed, withDestinationURL: URL(fileURLWithPath: "/bin/sleep"))
        #expect(
            !ExtensionPrivilegedCarrierProcess.predatesHost(
                executable: installed, user: getuid(), parent: getppid()))
        try FileManager.default.removeItem(at: installed)
        try Data().write(to: installed)
        #expect(
            ExtensionPrivilegedCarrierProcess.predatesHost(
                executable: installed, user: getuid(), parent: getppid()))
        #expect(
            !ExtensionPrivilegedCarrierProcess.predatesHost(
                executable: installed, user: getuid(), parent: getpid()))
    }
}

@MainActor private final class FailingStartTransport: ExtensionPrivilegedTransport {
    let failure: ExtensionPrivilegedError
    let invalidated: @MainActor () -> Void
    init(failure: ExtensionPrivilegedError, invalidated: @escaping @MainActor () -> Void) {
        self.failure = failure; self.invalidated = invalidated
    }
    func activate(source: URL, owner: String, version: String) async throws { throw failure }
    func invoke(_ command: String, payload: Data) async throws -> Data { Data() }
    func release() async throws {}
    func invalidate() { invalidated() }
}

private final class SyntheticCarrier: NSObject, NSXPCListenerDelegate, ExtensionPrivilegedProtocol,
    @unchecked Sendable
{
    let answersStart: Bool
    let rejects: Bool
    private let listener = NSXPCListener.anonymous()

    init(answersStart: Bool, rejects: Bool = false) {
        self.answersStart = answersStart; self.rejects = rejects
        super.init()
        listener.delegate = self
        listener.resume()
    }

    func stop() { listener.invalidate() }

    @MainActor func transport() -> ExtensionPrivilegedXPC {
        ExtensionPrivilegedXPC(
            connection: NSXPCConnection(listenerEndpoint: listener.endpoint), hostIdentifier: nil,
            answerLimit: .seconds(1), invalidated: {})
    }

    func listener(
        _ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: ExtensionPrivilegedProtocol.self)
        connection.exportedObject = self
        connection.resume()
        if rejects { connection.invalidate() }
        return true
    }

    func activate(
        _ source: String, owner: String, version: String,
        reply: @escaping @Sendable (NSError?) -> Void
    ) {
        if answersStart { reply(nil) }
    }

    func invoke(
        _ command: String, payload: Data, reply: @escaping @Sendable (Data?, NSError?) -> Void
    ) {}

    func release(reply: @escaping @Sendable (NSError?) -> Void) { reply(nil) }
}
