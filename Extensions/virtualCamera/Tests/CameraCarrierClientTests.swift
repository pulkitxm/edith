import Foundation
import Testing
@testable import VirtualCameraExtension

@MainActor
private final class CameraControlProbe: CameraCarrierControlling {
    var currentStatus: CameraCarrierStatus? = .init(
        phase: "idle", ownsProvider: false, pending: false)
    var changed: ((CameraCarrierStatus) -> Void)?
    var restartRequired = false
    var calls: [String] = []
    func activate() async throws {
        calls.append("activate");
        publish(.init(phase: "active", ownsProvider: true, pending: false))
    }
    func deactivate() async throws {
        calls.append("deactivate")
        if restartRequired {
            publish(.init(phase: "restartRequired", ownsProvider: true, pending: false));
            throw CocoaError(.userCancelled)
        }
        publish(.init(phase: "stopped", ownsProvider: false, pending: false))
    }
    func prepareMicrophone() async throws { calls.append("microphone") }
    func prepareDisable(providerVisible: Bool) async throws { try await deactivate() }
    func publish(_ status: CameraCarrierStatus) { currentStatus = status; changed?(status) }
}

@Suite(.serialized) @MainActor struct CameraCarrierClientTests {
    @MainActor private final class Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "camera-client-" + UUID().uuidString)
        let mode: String
        var preparations = 0
        init(mode: String = "normal") throws {
            self.mode = mode
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Data(Self.server.utf8).write(to: root.appendingPathComponent("carrier.py"))
        }
        deinit { try? FileManager.default.removeItem(at: root) }
        func client(timeout: Duration = .seconds(2)) -> CameraCarrierClient {
            CameraCarrierClient(
                timeout: timeout,
                prepare: { [self] in
                    preparations += 1; return root
                },
                launch: { [self] _ in
                    let process = Process();
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
                    process.arguments = [
                        root.appendingPathComponent("carrier.py").path, mode,
                        root.appendingPathComponent("exited").path,
                    ]
                    process.standardInput = Pipe(); process.standardOutput = Pipe();
                    process.standardError = FileHandle.nullDevice
                    try process.run(); return process
                })
        }
        static let server = """
            import json,sys,time
            mode=sys.argv[1]
            active=False
            for line in sys.stdin:
                request=json.loads(line)
                operation=request['operation']
                error=None
                phase='active' if active else 'stopped'
                if operation=='activate':
                    active=True
                    phase='active'
                    if mode=='timeout':
                        print(json.dumps({'status':{'phase':phase,'ownsProvider':active,'pending':True}}),flush=True)
                        continue
                    if mode=='cancel': time.sleep(0.03)
                elif operation in ['deactivate','prepareDisable']:
                    if mode=='restart':
                        phase='restartRequired'
                        error='Restart macOS to finish disabling the fixture provider.'
                    else:
                        active=False
                        phase='stopped'
                elif operation=='microphonePrepare': error='Synthetic microphone approval was rejected.'
                reply={'token':request['token'],'status':{'phase':phase,'ownsProvider':active,'pending':False}}
                if error: reply['error']=error
                print(json.dumps(reply),flush=True)
            open(sys.argv[2],'w').write('released')
            """
    }

    @Test func realPipeRoundTripDrainsProcessAndRetainsOnePreparation() async throws {
        let fixture = try Fixture()
        let client = fixture.client()
        try await client.activate()
        #expect(client.currentStatus?.phase == "active")
        #expect(client.currentStatus?.ownsProvider == true)
        try await client.deactivate()
        try await client.activate()
        try await client.prepareDisable(providerVisible: true)
        #expect(fixture.preparations == 1)
        #expect(client.currentStatus?.ownsProvider == false)
        #expect(
            FileManager.default.fileExists(
                atPath: fixture.root.appendingPathComponent("exited").path))
    }

    @Test func cancellationKeepsLateOwnershipVisibleUntilAcknowledgedDisable() async throws {
        let fixture = try Fixture(mode: "cancel")
        let client = fixture.client()
        let activation = Task { try await client.activate() }
        try await Task.sleep(for: .milliseconds(20))
        activation.cancel()
        await #expect(throws: CancellationError.self) { try await activation.value }
        try await wait { client.currentStatus?.ownsProvider == true }
        try await client.prepareDisable(providerVisible: true)
        #expect(client.currentStatus?.ownsProvider == false)
    }

    @Test func timedOutRequestPreservesOwnershipAndCleanupCanStillComplete() async throws {
        let fixture = try Fixture(mode: "timeout")
        let client = fixture.client(timeout: .milliseconds(100))
        await #expect(throws: (any Error).self) { try await client.activate() }
        #expect(client.currentStatus?.ownsProvider == true)
        try await client.prepareDisable(providerVisible: true)
        #expect(client.currentStatus?.ownsProvider == false)
    }

    @Test func microphoneFailureDoesNotClaimProviderActivation() async throws {
        let fixture = try Fixture()
        let client = fixture.client()
        await #expect(throws: (any Error).self) { try await client.prepareMicrophone() }
        #expect(client.currentStatus?.ownsProvider == false)
        try await client.prepareDisable(providerVisible: false)
    }

    @Test func managerUsesCarrierAndKeepsRestartRequiredState() async throws {
        let client = CameraControlProbe()
        let manager = VirtualCameraExtensionManager(client: client)
        manager.install()
        try await wait { manager.phase == .installed }
        #expect(client.calls == ["activate"])
        client.restartRequired = true
        manager.uninstall()
        try await wait { manager.phase == .restartRequired }
        manager.refresh(); manager.refreshDetached(); manager.install()
        #expect(manager.phase == .restartRequired)
        #expect(!manager.phase.canInstall)
        #expect(client.currentStatus?.ownsProvider == true)
        #expect(client.calls == ["activate", "deactivate"])
        await manager.shutdown()
    }

    @Test func closedManagerIgnoresLateCarrierPublication() async {
        let client = CameraControlProbe()
        let manager = VirtualCameraExtensionManager(client: client)
        manager.refresh()
        let callback = client.changed
        await manager.shutdown()
        callback?(.init(phase: "active", ownsProvider: true, pending: false))
        manager.install()
        #expect(manager.phase == .notInstalled)
        #expect(client.calls.isEmpty)
        #expect(client.changed == nil)
    }

    private func wait(_ predicate: @MainActor () -> Bool) async throws {
        for _ in 0..<1000 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        Issue.record("Camera client did not reach its expected state")
        throw CancellationError()
    }
}
