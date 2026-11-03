import AppKit
#if SWIFT_PACKAGE
import WorkerFixtureSupport
#endif
import EdithExtensionSupport
import EdithExtensionCommands
import EdithExtensionUI
import SwiftUI

@MainActor
final class CompanionService: ExtensionService {
    private unowned let runtime: ExtensionServiceRuntime
    private let fixtureAdmission: (NSDictionary) throws -> WorkerFixtureAdmission?
    private let ambientPolicy = ExtensionAmbientPolicy(jobs: [
        CompanionMonitor.jobID: .init(ambient: 60, live: 20)
    ])
    private let settingsChanged: @MainActor () -> Void
    private var worker: CompanionWorker?
    private var uiBridge: CompanionUIBridge?
    private var uiWorkspace: CompanionWorkspaceSession?
    private var uiEngine: CompanionUIEngine?
    private var engineClient: ExtensionEngineClient?
    private var surface: CompanionSurface?
    private var cliStreams: ExtensionCLIStreams?
    private var uiDrains: [UUID: Task<Void, Never>] = [:]
    private var drainWorker: CompanionWorker?
    private var drainEngine: CompanionUIEngine?
    private var drainWorkspace: CompanionWorkspaceSession?
    private var drainBridge: CompanionUIBridge?
    private var drainStreams: ExtensionCLIStreams?

    init(
        runtime: ExtensionServiceRuntime,
        settingsChanged: @escaping @MainActor () -> Void = { IPC.post(IPC.Name.settingsChanged) },
        fixtureAdmission: @escaping (NSDictionary) throws -> WorkerFixtureAdmission? = {
            try WorkerFixtureAdmission.current(
                extensionID: "companion", context: $0,
                roleBundle: Bundle(for: CompanionService.self))
        }
    ) {
        self.runtime = runtime
        self.fixtureAdmission = fixtureAdmission
        self.settingsChanged = settingsChanged
    }

    var allowsUIDuringRetirement: Bool { true }
    var isRunning: Bool { worker?.isStopped == false }
    var preparesUIToClose: Bool { true }

    func start(_ context: ExtensionHostContext) -> Bool {
        let input = context.input
        let fixture: Bool
        do { fixture = try fixtureAdmission(input) != nil } catch { return false }
        do { try ambientPolicy.apply(context: input) } catch { return false }
        guard worker == nil else { return true }
        if !fixture {
            do {
                try ambientPolicy.start { [weak self] in self?.worker?.monitor.reschedule() }
            } catch { return false }
        }
        let policy = ambientPolicy
        let monitor = CompanionMonitor(interval: {
            policy.interval(for: CompanionMonitor.jobID)
        })
        let worker = CompanionWorker(monitor: monitor)
        self.worker = worker
        uiEngine = CompanionUIEngine(worker: worker)
        CompanionCLIEnvironment.stopGenerations = { [weak self] in
            (self?.uiEngine?.stopGenerations() ?? 0) + CompanionGeneration.stopAll()
        }
        surface = CompanionSurface(
            monitor: worker.monitor,
            isStopped: { [weak worker] in worker?.isStopped != false },
            open: { [weak worker] id in worker?.openEpisode(id) })
        worker.start()
        TextEditingCommands.install()
        return true
    }

    func synchronize(_ context: ExtensionHostContext) -> Bool {
        guard !(runtime.isSuspended || runtime.isStopping) else { return false }
        let input = context.input
        do { _ = try fixtureAdmission(input) } catch { return false }
        do { try ambientPolicy.apply(context: input) } catch { return false }
        if input["ambientPolicyOnly"] as? Bool != true { settingsChanged() }
        return true
    }

    func invoke(_ command: String, payload: Data) async throws -> Data {
        guard let worker else { throw ExtensionPeerError.unavailable }
        if command == "companion.cli.catalog" {
            return try ExtensionCLICatalog.data(
                CompanionCommand.self, owner: "companion", payload: payload, streaming: true)
        }
        if command.hasPrefix("companion.cli.") {
            if cliStreams == nil {
                cliStreams = try ExtensionCLIStreams(owner: "companion")
            }
            guard let streams = cliStreams else { throw ExtensionPeerError.unavailable }
            return try CompanionCLIExecution.stream(
                streams, operation: command, payload: payload)
        }
        if command == "companion.cli" {
            let request = try JSONDecoder().decode(ExtensionCLIRequest.self, from: payload)
            return try JSONEncoder().encode(
                try await CompanionCLIExecution.run(request))
        }
        if command.hasPrefix("companion.ui."), let engine = uiEngine {
            return try await engine.execute(command, payload: payload)
        }
        if command.hasPrefix("surface.") {
            guard let surface else { throw ExtensionPeerError.unavailable }
            return try await surface.execute(command, payload: payload)
        }
        return try await worker.execute(command, payload: payload)
    }

    func configureUI(_ configuration: ExtensionUIConfiguration) -> Bool {
        guard let client = configuration.engineClient else { return false }
        return openWorkspace(client: client) != nil
    }

    func openWorkspace(client: ExtensionEngineClient) -> CompanionWorkspaceSession? {
        guard !(runtime.isSuspended || runtime.isStopping), uiDrains.count < 8,
            engineClient == nil
        else { return nil }
        let bridge = CompanionUIBridge(client: client)
        let workspace = CompanionWorkspaceSession(
            privacy: ExtensionSharedState.current.map { SurfacePrivacyState(channel: $0) },
            remote: bridge)
        engineClient = client
        uiBridge = bridge
        uiWorkspace = workspace
        TextEditingCommands.install()
        return workspace
    }

    func view(for presentation: UUID) -> NSViewController? {
        guard !(runtime.isSuspended || runtime.isStopping), let workspace = uiWorkspace else {
            return nil
        }
        return NSHostingController(
            rootView: ExtensionPageHost { CompanionPage(session: workspace) })
    }

    func stopUI(for presentation: UUID?) -> [Task<Void, Never>] {
        let drain = retireUI()
        cleanUpTextEditing()
        return drain.map { [$0] } ?? []
    }

    func prepareUIToClose(_ presentation: UUID) async -> String? {
        guard engineClient == nil || engineClient?.presentationID == presentation else {
            return "Invalid Companion presentation."
        }
        await retireUI()?.value
        while let task = uiDrains.values.first { await task.value }
        return nil
    }

    func cancelPendingWork() {
        drainWorker = worker
        drainEngine = uiEngine
        drainWorkspace = uiWorkspace
        drainBridge = uiBridge
        drainStreams = cliStreams
        drainWorker?.cancelPendingCommands()
        drainEngine?.cancelPendingCommands()
        drainWorkspace?.cancelPendingCommands()
        drainBridge?.stop()
        drainStreams?.stop()
        _ = CompanionCLIExecution.stopChats()
        CompanionTransport.shared.close()
    }

    func drain() async {
        let originalWorker = drainWorker
        let engine = drainEngine
        let workspace = drainWorkspace
        let bridge = drainBridge
        let streams = drainStreams
        await originalWorker?.monitor.cancelDelivery()
        await streams?.stopAndWait()
        await CompanionCLIExecution.stopChatsAndWait()
        await engine?.cancelAndWait()
        await originalWorker?.cancelAndWait()
        await workspace?.cancelAndWait()
        await bridge?.stopAndWait()
        await CompanionTransport.shared.closeAndWait()
        while let task = uiDrains.values.first { await task.value }
    }

    func finishBeforeStop() async {
        ambientPolicy.stop()
    }

    func teardown() async {
        let owner = worker
        let engine = uiEngine
        let workspace = uiWorkspace
        let retirement = retireUI()
        worker = nil
        uiEngine = nil
        surface = nil
        cliStreams = nil
        drainWorker = nil
        drainEngine = nil
        drainWorkspace = nil
        drainBridge = nil
        drainStreams = nil
        await retirement?.value
        while let task = uiDrains.values.first { await task.value }
        await engine?.shutdown()
        await owner?.shutdown()
        workspace?.shutdown()
        cleanUpTextEditing()
    }

    @discardableResult
    private func retireUI() -> Task<Void, Never>? {
        let workspace = uiWorkspace
        let bridge = uiBridge
        let client = engineClient
        guard workspace != nil || bridge != nil || client != nil else { return nil }
        workspace?.cancelPendingCommands()
        bridge?.stop()
        let id = UUID()
        let drain = Task { [self, workspace, bridge, client] in
            defer { uiDrains[id] = nil }
            await workspace?.cancelAndWait()
            await bridge?.stopAndWait()
            workspace?.shutdown()
            client?.invalidate()
        }
        uiDrains[id] = drain
        uiWorkspace = nil
        uiBridge = nil
        engineClient = nil
        return drain
    }

    private func cleanUpTextEditing() {
        ExtensionUIResources.cleanup(of: runtime, key: "textEditing") {
            TextEditingCommands.shutdown()
        }
    }
}

@MainActor
func makeCompanionRuntime() -> ExtensionServiceRuntime {
    final class BundleAnchor {}
    return ExtensionServiceRuntime(
        id: "companion", role: "app", bundle: Bundle(for: BundleAnchor.self)
    ) { CompanionService(runtime: $0) }
}

@_cdecl("edith_extension_create")
public func createExtension() -> UnsafeMutableRawPointer? {
    UnsafeMutableRawPointer(
        bitPattern: MainActor.assumeIsolated {
            UInt(bitPattern: Unmanaged.passRetained(makeCompanionRuntime()).toOpaque())
        })
}
