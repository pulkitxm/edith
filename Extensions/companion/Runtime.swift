import AppKit
#if SWIFT_PACKAGE
import WorkerFixtureSupport
#endif
import EdithExtensionSupport
import EdithExtensionCommands
import EdithExtensionUI
import SwiftUI

@MainActor @objc(EdithCompanionExtensionRuntime)
final class ExtensionRuntime: NSObject {
    private let fixtureAdmission: (NSDictionary) throws -> WorkerFixtureAdmission?
    private let ambientPolicy = ExtensionAmbientPolicy(jobs: [
        CompanionMonitor.jobID: .init(ambient: 60, live: 20)
    ])
    private let settingsChanged: @MainActor () -> Void
    private var worker: CompanionWorker?
    private var uiWorkspace: CompanionWorkspaceSession?
    private var uiEngine: CompanionUIEngine?
    private var engineClient: ExtensionEngineClient?
    private var surface: CompanionSurface?
    private let commands = ExtensionCommandRegistry()
    private var cliStreams: ExtensionCLIStreams?
    private var commandDrain: Task<Void, Never>?
    private var resourceStop: Task<Void, Never>?
    private var commandsSuspended = false
    private var uiDrains: [UUID: Task<Void, Never>] = [:]

    init(
        settingsChanged: @escaping @MainActor () -> Void = { IPC.post(IPC.Name.settingsChanged) },
        fixtureAdmission: @escaping (NSDictionary) throws -> WorkerFixtureAdmission? = {
            try WorkerFixtureAdmission.current(
                extensionID: "companion", context: $0,
                roleBundle: Bundle(for: ExtensionRuntime.self))
        }
    ) {
        self.fixtureAdmission = fixtureAdmission
        self.settingsChanged = settingsChanged
        super.init()
    }

    @objc func invoke(_ request: NSDictionary, completion: @escaping (NSData?, NSString?) -> Void) {
        commands.invoke(request, completion: completion) { [weak self] command, payload in
            guard let self, let worker = self.worker else { throw ExtensionPeerError.unavailable }
            if command.hasPrefix("companion.cli.") {
                if self.cliStreams == nil {
                    self.cliStreams = try ExtensionCLIStreams(owner: "companion")
                }
                guard let streams = self.cliStreams else { throw ExtensionPeerError.unavailable }
                return try CompanionCLIExecution.stream(
                    streams, operation: command, payload: payload)
            }
            if command == "companion.cli" {
                let request = try JSONDecoder().decode(ExtensionCLIRequest.self, from: payload)
                return try JSONEncoder().encode(
                    try await CompanionCLIExecution.run(request))
            }
            if command.hasPrefix("companion.ui."), let engine = self.uiEngine {
                return try await engine.execute(command, payload: payload)
            }
            if command.hasPrefix("surface.") {
                guard let surface = self.surface else { throw ExtensionPeerError.unavailable }
                return try await surface.execute(command, payload: payload)
            }
            return try await worker.execute(command, payload: payload)
        }
    }

    @objc(suspendCommandsWithCompletion:)
    func suspendCommands(completion: @escaping () -> Void) {
        let drain = beginCommandDrain()
        Task { [self] in
            await drain.value
            await resourceStop?.value
            withExtendedLifetime(self) { completion() }
        }
    }

    private func beginCommandDrain() -> Task<Void, Never> {
        let originalWorker = worker
        let engine = uiEngine
        let workspace = uiWorkspace
        let bridge = CompanionTransport.shared.remoteBridge
        let streams = cliStreams
        commandsSuspended = true
        _ = commands.suspend()
        if let commandDrain { return commandDrain }
        originalWorker?.cancelPendingCommands()
        engine?.cancelPendingCommands()
        workspace?.cancelPendingCommands()
        bridge?.stop()
        streams?.stop()
        _ = CompanionCLIExecution.stopChats()
        CompanionTransport.shared.close()
        if let commandDrain { return commandDrain }
        let task = Task { [self] in
            await originalWorker?.monitor.cancelDelivery()
            _ = await commands.suspendAndWait()
            await streams?.stopAndWait()
            await CompanionCLIExecution.stopChatsAndWait()
            await engine?.cancelAndWait()
            await originalWorker?.cancelAndWait()
            await workspace?.cancelAndWait()
            await bridge?.stopAndWait()
            await CompanionTransport.shared.closeAndWait()
            while let task = uiDrains.values.first { await task.value }
        }
        commandDrain = task
        return task
    }

    private func retireUI() {
        let workspace = uiWorkspace
        let bridge = CompanionTransport.shared.remoteBridge
        guard workspace != nil || bridge != nil else { return }
        workspace?.cancelPendingCommands()
        bridge?.stop()
        let id = UUID()
        uiDrains[id] = Task { [self, workspace, bridge] in
            defer { uiDrains[id] = nil }
            await workspace?.cancelAndWait()
            await bridge?.stopAndWait()
            workspace?.shutdown()
        }
        uiWorkspace = nil
        CompanionTransport.shared.configureRemote(nil)
        engineClient?.invalidate(); engineClient = nil
    }

    @objc(prepareToStopWithCompletion:)
    func prepareToStop(completion: @escaping () -> Void) {
        let stop = beginResourceStop()
        Task { [self] in
            await stop.value
            withExtendedLifetime(self) { completion() }
        }
    }

    private func beginResourceStop() -> Task<Void, Never> {
        if let resourceStop { return resourceStop }
        let owner = worker
        let engine = uiEngine
        let workspace = uiWorkspace
        let drain = beginCommandDrain()
        if let resourceStop { return resourceStop }
        retireUI()
        ambientPolicy.stop()
        worker = nil; uiEngine = nil; surface = nil; cliStreams = nil
        let task = Task { [self] in
            await drain.value
            await commands.shutdownAndWait()
            await engine?.shutdown()
            await owner?.shutdown()
            workspace?.shutdown()
            TextEditingCommands.shutdown()
        }
        resourceStop = task
        return task
    }

    @objc func execute(_ input: NSDictionary) -> NSObject {
        switch input["operation"] as? String {
        case "describe":
            let bundle = Bundle(for: ExtensionRuntime.self)
            return [
                "id": "companion", "role": "app",
                "version": bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                    as? String ?? "",
                "hostABI": bundle.object(forInfoDictionaryKey: "EdithHostABI") as? String ?? "",
            ] as NSDictionary
        case "configureUI":
            guard !commandsSuspended, uiDrains.count < 8, engineClient == nil,
                let configuration = ExtensionUIConfiguration(context: input),
                configuration.extensionID == "companion", let client = configuration.engineClient
            else { return ["ok": false] as NSDictionary }
            engineClient = client
            let bridge = CompanionUIBridge(client: client)
            CompanionTransport.shared.configureRemote(bridge)
            uiWorkspace = CompanionWorkspaceSession(remote: bridge)
            TextEditingCommands.install()
        case "stopUI":
            retireUI()
            TextEditingCommands.shutdown()
        case "start":
            guard !commandsSuspended else { return ["ok": false] as NSDictionary }
            let fixture: Bool
            do { fixture = try fixtureAdmission(input) != nil } catch {
                return ["ok": false] as NSDictionary
            }
            guard let suite = input["defaultsSuite"] as? String,
                suite == ProcessInfo.processInfo.environment["EDITH_SHARED_DEFAULTS_SUITE"]
            else { return ["ok": false] as NSDictionary }
            do { try ambientPolicy.apply(context: input) } catch {
                return ["ok": false] as NSDictionary
            }
            guard worker == nil else { return ["ok": true] as NSDictionary }
            if !fixture {
                do {
                    try ambientPolicy.start { [weak self] in self?.worker?.monitor.reschedule() }
                } catch { return ["ok": false] as NSDictionary }
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
        case "view":
            guard !commandsSuspended else { return ["ok": false] as NSDictionary }
            guard let workspace = uiWorkspace else { return ["ok": false] as NSDictionary }
            return NSHostingController(
                rootView: ExtensionPageHost {
                    if workspace.preferences?.loaded != false {
                        CompanionPage(session: workspace)
                    } else {
                        PageScaffold(header: { PageHeader("Companion") }) {
                            PageLoading(
                                state: workspace.preferences?.error == nil ? .loading : .error,
                                message: workspace.preferences?.error
                                    ?? "Loading Companion settings.", layout: .cards,
                                retry: { workspace.preferences?.refresh() }
                            ) { EmptyView() }
                        }
                    }
                })
        case "cancelCommand": commands.cancel(input["token"] as? String ?? "")
        case "synchronize":
            guard !commandsSuspended else { return ["ok": false] as NSDictionary }
            do { _ = try fixtureAdmission(input) } catch { return ["ok": false] as NSDictionary }
            do { try ambientPolicy.apply(context: input) } catch {
                return ["ok": false] as NSDictionary
            }
            if input["ambientPolicyOnly"] as? Bool != true { settingsChanged() }
        case "stop":
            _ = beginResourceStop()
        case "status": return ["ok": true, "running": worker?.isStopped == false] as NSDictionary
        default: return ["ok": false] as NSDictionary
        }
        return ["ok": true] as NSDictionary
    }
}

@_cdecl("edith_extension_create")
public func createExtension() -> UnsafeMutableRawPointer? {
    UnsafeMutableRawPointer(
        bitPattern: MainActor.assumeIsolated {
            UInt(bitPattern: Unmanaged.passRetained(ExtensionRuntime()).toOpaque())
        })
}
