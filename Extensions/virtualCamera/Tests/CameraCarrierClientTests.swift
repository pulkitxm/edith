import EdithExtensionSupport
import Foundation
import ServiceManagement
import Testing
@testable import VirtualCameraExtension

@MainActor
private final class CameraControlProbe: CameraCarrierControlling {
    var currentStatus: CameraCarrierStatus? = .init(
        phase: "idle", ownsProvider: false, pending: false)
    var changed: ((CameraCarrierStatus) -> Void)?
    var restartRequired = false
    var calls: [String] = []
    var failure: Error?
    func activate() async throws {
        calls.append("activate");
        if let failure { throw failure }
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
    func prepareDisable(providerVisible: Bool) async throws { try await deactivate() }
    func publish(_ status: CameraCarrierStatus) { currentStatus = status; changed?(status) }
}

@Suite(.serialized) @MainActor struct CameraCarrierClientTests {
    @MainActor private final class Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "camera-client-" + UUID().uuidString)
        let mode: String
        let startupDelay: Double
        var preparations = 0
        var launches = 0
        private(set) var preparationDuration: Duration?
        private(set) var process: Process?
        init(mode: String = "normal", startupDelay: Double = 0) throws {
            self.mode = mode
            self.startupDelay = startupDelay
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Data(Self.server.utf8).write(to: root.appendingPathComponent("carrier.py"))
        }
        deinit {
            if let process, process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
            try? FileManager.default.removeItem(at: root)
        }
        var admitted: Bool {
            FileManager.default.fileExists(atPath: root.appendingPathComponent("admitted").path)
        }
        var drained: Bool {
            process?.isRunning == false
                && FileManager.default.fileExists(
                    atPath: root.appendingPathComponent("exited").path)
        }
        func releaseReply() throws {
            try Data().write(to: root.appendingPathComponent("release"))
        }
        func client(timeout: Duration = .seconds(2)) -> CameraCarrierClient {
            CameraCarrierClient(
                timeout: timeout,
                prepare: { [self] in
                    preparations += 1
                    let started = ContinuousClock.now
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
                    process.arguments = [
                        root.appendingPathComponent("carrier.py").path, mode,
                        root.appendingPathComponent("exited").path, String(startupDelay),
                    ]
                    process.standardInput = Pipe(); process.standardOutput = Pipe()
                    process.standardError = FileHandle.nullDevice
                    try process.run()
                    self.process = process
                    try await waitUntilReady(until: started.advanced(by: .seconds(10)))
                    preparationDuration = started.duration(to: ContinuousClock.now)
                    return root
                },
                launch: { [self] url in
                    launches += 1
                    guard url == root, let process, process.isRunning,
                        FileManager.default.fileExists(
                            atPath: root.appendingPathComponent("ready").path)
                    else { throw CocoaError(.executableLoad) }
                    return process
                })
        }
        func waitUntilReady(
            until deadline: ContinuousClock.Instant = ContinuousClock.now.advanced(by: .seconds(10))
        ) async throws {
            while true {
                try Task.checkCancellation()
                if let process {
                    guard process.isRunning else { throw CocoaError(.executableLoad) }
                    if FileManager.default.fileExists(
                        atPath: root.appendingPathComponent("ready").path)
                    {
                        return
                    }
                }
                guard ContinuousClock.now < deadline else {
                    throw CocoaError(.executableRuntimeMismatch)
                }
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        static let server = """
            import json,pathlib,sys,time
            mode=sys.argv[1]
            root=pathlib.Path(sys.argv[2]).parent
            time.sleep(float(sys.argv[3]))
            active=False
            (root/'ready').write_text('ready')
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
                    if mode=='cancel':
                        (root/'admitted').write_text(request['token'])
                        deadline=time.monotonic()+5
                        while not (root/'release').exists():
                            if time.monotonic()>=deadline: raise TimeoutError('reply was not released')
                            time.sleep(0.001)
                elif operation in ['deactivate','prepareDisable']:
                    if mode=='restart':
                        phase='restartRequired'
                        error='Restart macOS to finish disabling the fixture provider.'
                    else:
                        active=False
                        phase='stopped'
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
        #expect(fixture.launches == 1)
        #expect(client.currentStatus?.ownsProvider == false)
        #expect(fixture.drained)
    }

    @Test func delayedFixtureStartupCompletesBeforeTheUnchangedRequestDeadlineBegins() async throws
    {
        let fixture = try Fixture(startupDelay: 2.1)
        let client = fixture.client(timeout: .seconds(2))
        try await client.activate()
        #expect(fixture.preparationDuration.map { $0 >= .milliseconds(2100) } == true)
        #expect(fixture.preparations == 1)
        #expect(fixture.launches == 1)
        #expect(client.currentStatus?.phase == "active")
        try await client.prepareDisable(providerVisible: true)
        #expect(fixture.preparations == 1)
        #expect(fixture.launches == 1)
        #expect(fixture.drained)
    }

    @Test func cancellationKeepsLateOwnershipVisibleUntilAcknowledgedDisable() async throws {
        let fixture = try Fixture(mode: "cancel")
        let client = fixture.client()
        let activation = Task { try await client.activate() }
        try await fixture.waitUntilReady()
        try await wait { fixture.admitted }
        #expect(client.currentStatus == nil)
        activation.cancel()
        await #expect(throws: CancellationError.self) { try await activation.value }
        #expect(client.currentStatus == nil)
        try fixture.releaseReply()
        try await wait { client.currentStatus?.ownsProvider == true }
        try await client.prepareDisable(providerVisible: true)
        #expect(client.currentStatus?.ownsProvider == false)
        #expect(fixture.drained)
    }

    @Test func alreadyCancelledRequestDoesNotPrepareOrLaunchCarrier() async throws {
        let fixture = try Fixture()
        let client = fixture.client()
        let activation = Task { try await client.activate() }
        activation.cancel()
        await #expect(throws: CancellationError.self) { try await activation.value }
        #expect(fixture.preparations == 0)
        #expect(fixture.launches == 0)
        #expect(fixture.process == nil)
        #expect(client.currentStatus == nil)
        try await client.prepareDisable(providerVisible: false)
        #expect(fixture.preparations == 0)
        #expect(fixture.launches == 0)
    }

    @Test func cancellationDuringReplyPublicationCannotReturnSuccess() async throws {
        let fixture = try Fixture(mode: "cancel")
        let client = fixture.client()
        let activation = Task { try await client.activate() }
        try await fixture.waitUntilReady()
        try await wait { fixture.admitted }
        client.changed = { status in
            if status.phase == "active" { activation.cancel() }
        }
        try fixture.releaseReply()
        await #expect(throws: CancellationError.self) { try await activation.value }
        #expect(client.currentStatus?.ownsProvider == true)
        #expect(client.currentStatus?.pending == false)
        client.changed = nil
        try await client.prepareDisable(providerVisible: true)
        #expect(client.currentStatus?.ownsProvider == false)
        #expect(fixture.drained)
    }

    @Test func timedOutRequestPreservesOwnershipAndCleanupCanStillComplete() async throws {
        let fixture = try Fixture(mode: "timeout")
        let client = fixture.client(timeout: .milliseconds(100))
        await #expect(throws: (any Error).self) { try await client.activate() }
        #expect(client.currentStatus?.ownsProvider == true)
        try await client.prepareDisable(providerVisible: true)
        #expect(client.currentStatus?.ownsProvider == false)
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

    @Test(arguments: [true, false]) func installFailureSurvivesRefreshUntilTheCameraAppears(
        carrierStarted: Bool
    ) async throws {
        let bundle = FileManager.default.temporaryDirectory.appendingPathComponent(
            "camera-failure-\(UUID().uuidString).app")
        defer { try? FileManager.default.removeItem(at: bundle) }
        var visible = false
        let client = CameraControlProbe()
        if !carrierStarted { client.currentStatus = nil }
        client.failure = CocoaError(.featureUnsupported)
        let manager = VirtualCameraExtensionManager(
            environment: .init(
                bundleURL: bundle, hasInstallEntitlement: { true }, deviceVisible: { visible },
                canPrepareLocation: true), client: client)
        try FileManager.default.createDirectory(
            at: manager.extensionBundleURL, withIntermediateDirectories: true)
        manager.refresh()
        manager.install()
        try await wait { if case .failed = manager.phase { true } else { false } }
        let failed = manager.phase
        manager.refresh()
        manager.refreshDetached()
        try await Task.sleep(for: .milliseconds(50))
        #expect(manager.phase == failed)
        #expect(failed.canInstall)
        client.failure = nil
        manager.install()
        try await wait { manager.phase == .installed }
        #expect(client.calls == ["activate", "activate"])
        client.failure = CocoaError(.featureUnsupported)
        await manager.shutdown()
        if !carrierStarted {
            let late = VirtualCameraExtensionManager(
                environment: .init(
                    bundleURL: bundle, hasInstallEntitlement: { true },
                    deviceVisible: { visible }, canPrepareLocation: true), client: client)
            client.currentStatus = nil
            late.refresh()
            late.install()
            try await wait { if case .failed = late.phase { true } else { false } }
            visible = true
            late.refresh()
            #expect(late.phase == .installed)
            await late.shutdown()
        }
    }

    @Test func installRegistersACarrierMacOSHasNeverSeen() {
        func steps(_ status: SMAppService.Status) -> [String] {
            var steps: [String] = []
            CameraAppWorker.approveCarrier(
                status: status, register: { steps.append("register") },
                requestApproval: { steps.append("approve") })
            return steps
        }
        #expect(steps(.notFound) == ["register", "approve"])
        #expect(steps(.notRegistered) == ["approve"])
        #expect(steps(.requiresApproval) == ["approve"])
        #expect(steps(.enabled).isEmpty)
    }

    @Test func failedCarrierInstallReleasesThePrivilegedWorker() async throws {
        let host = "com.pulkit.edith"
        let installed = "/Applications/Edith Extensions/com.pulkit.edith.cameraCarrier.app"
        func steps(_ run: () async throws -> Data) async -> ([String], URL?) {
            var steps: [String] = []
            let url = try? await CameraAppWorker.installCarrier(
                host: host, run: run, release: { steps.append("release") },
                abandon: { steps.append("abandon") })
            return (steps, url)
        }
        let success = await steps {
            try JSONSerialization.data(withJSONObject: ["path": installed])
        }
        #expect(success.0 == ["release"])
        #expect(success.1?.path == installed)
        let rejected = await steps { throw ExtensionPeerError.rejected("synthetic failure") }
        #expect(rejected.0 == ["release", "abandon"])
        #expect(rejected.1 == nil)
        let foreign = await steps {
            try JSONSerialization.data(withJSONObject: ["path": "/Applications/Other.app"])
        }
        #expect(foreign.0 == ["release", "abandon"])
        #expect(foreign.1 == nil)
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
