import AppKit
#if SWIFT_PACKAGE
import WorkerFixtureSupport
#endif
import EdithExtensionSupport
import EdithExtensionUI
import EdithExtensionCommands
import SwiftUI

@MainActor
final class MachinesService: ExtensionService {
    private unowned let runtime: ExtensionServiceRuntime
    private let fixtureAdmission: (NSDictionary) throws -> WorkerFixtureAdmission?
    private var running = false
    private var peer: MachinePeerService?
    private var surface: MachineSurface?
    private var transport: MachinePeerTransport?
    private var cli: MachineCLIService?
    private var previewEngine: MachinePreviewEngine?
    private var directoryExport: MachineDirectoryExport?
    private var filesEngine: MachineFilesEngine?
    private var logEngine: MachineLogEngine?
    private var terminalEngine: MachineTerminalEngine?
    private var uiEngine: MachineUIEngine?
    private var windowNavigation: MachineHostWindowNavigationClient?
    private var engineModels: MachineEngineModels?
    private var uiClient: MachineUIClient?
    private var uiMachines: MachinesModel?
    private var uiWorkspace: WorkspaceModel?
    private let ambientPolicy = ExtensionAmbientPolicy(jobs: [
        MachineHealthLifecycle.jobID: .init(ambient: 300)
    ])
    private var health: MachineHealthLifecycle?
    private var uiRetirements: [UUID: Task<Void, Never>] = [:]
    private var suspendedWork: SuspendedWork?

    private struct SuspendedWork {
        let facade: MachineUIClient?
        let cli: MachineCLIService?
        let terminals: MachineTerminalEngine?
        let ui: MachineUIEngine?
        let previews: MachinePreviewEngine?
        let exports: MachineDirectoryExport?
        let logs: MachineLogEngine?
        let files: MachineFilesEngine?
        let peer: MachinePeerService?
    }

    init(
        runtime: ExtensionServiceRuntime,
        fixtureAdmission: @escaping (NSDictionary) throws -> WorkerFixtureAdmission? = {
            try WorkerFixtureAdmission.current(
                extensionID: "machines", context: $0,
                roleBundle: Bundle(for: MachinesService.self))
        }
    ) {
        self.runtime = runtime
        self.fixtureAdmission = fixtureAdmission
    }

    var isRunning: Bool { running }

    func invoke(_ command: String, payload: Data) async throws -> Data {
        guard running else { throw ExtensionPeerError.unavailable }
        if command == "machines.config.cli" {
            let request = try JSONDecoder().decode(ExtensionCLIRequest.self, from: payload)
            return try JSONEncoder().encode(
                try await ExtensionCLIExecution.run(ConfigCommand.self, request: request))
        }
        if command == "machines.cli.catalog" {
            guard payload == Data("{}".utf8) else { throw ExtensionPeerError.invalidRequest }
            return try MachineCLICatalog.encoded()
        }
        if command == "machines.cli.complete" {
            guard let models = engineModels else {
                throw ExtensionPeerError.unavailable
            }
            return try await MachineCLICatalog.complete(
                payload, session: { models.machines.session(for: $0) })
        }
        if command.hasPrefix("machines.ui.") {
            guard let uiEngine = uiEngine else { throw ExtensionPeerError.unavailable }
            return try await uiEngine.execute(command, payload: payload)
        }
        if command.hasPrefix("machines.cli.pty.") {
            guard let terminals = terminalEngine else {
                throw ExtensionPeerError.unavailable
            }
            return try await terminals.cliInvoke(command, payload: payload)
        }
        if command.hasPrefix("machines.cli.stream.") {
            guard let cli = cli else { throw ExtensionPeerError.unavailable }
            return try cli.invoke(command, payload: payload)
        }
        if command == "machines.cli" {
            guard let cli = cli else { throw ExtensionPeerError.unavailable }
            let request = try JSONDecoder().decode(ExtensionCLIRequest.self, from: payload)
            return try JSONEncoder().encode(try await cli.execute(request))
        }
        if command == "machines.health.snapshot" {
            guard payload == Data("{}".utf8), let health = health?.latest else {
                throw ExtensionPeerError.unavailable
            }
            return try JSONEncoder().encode(health)
        }
        if command.hasPrefix("machines.usage.snapshot.") {
            guard let transport = transport else { throw ExtensionPeerError.unavailable }
            return try transport.snapshots.execute(command, payload: payload)
        }
        if command.hasPrefix("surface.") {
            guard let surface = surface else { throw ExtensionPeerError.unavailable }
            return try await surface.execute(command, payload: payload)
        }
        guard let peer = peer else { throw ExtensionPeerError.unavailable }
        return try await peer.execute(command, payload: payload)
    }

    func start(_ context: ExtensionHostContext) -> Bool {
        let input = context.input
        let fixture: Bool
        do { fixture = try fixtureAdmission(input) != nil } catch { return false }
        guard uiClient == nil, !ExtensionHostRole.isInterfaceProcess else { return false }
        do { try ambientPolicy.apply(context: input) } catch { return false }
        if !running {
            if !fixture {
                do {
                    try ambientPolicy.start { [weak self] in self?.health?.reschedule() }
                } catch { return false }
            }
            let models = MachineEngineModels()
            engineModels = models
            let transport: MachinePeerTransport
            if fixture {
                transport = MachinePeerTransport(
                    usagePlatform: { _ in .linux },
                    usageRun: { _, _, _, _, maximumBytes in
                        let data = try MachineUsageFixtureSnapshot.load()
                        guard data.count <= maximumBytes else {
                            throw ExtensionPeerError.invalidRequest
                        }
                        return SSHExecResult(status: 0, stdout: data, stderr: Data())
                    })
            } else {
                transport = MachinePeerTransport()
            }
            self.transport = transport
            let usage = MachineUsageCollectionService { machine, force in
                return try await transport.collectUsage(machine, force: force)
            }
            peer = MachinePeerService(
                usage: usage,
                run: { machine, command, input, timeout in
                    if fixture { return "synthetic runtime output" }
                    return try await transport.run(
                        machine, command: command, stdin: input, timeout: timeout)
                },
                forward: { machine, forward in
                    if fixture { return true }
                    return try await transport.forward(machine, forward: forward)
                },
                prepareConnection: { machine in
                    guard !fixture else { throw ExtensionPeerError.unavailable }
                    return try await transport.prepareConnection(machine)
                })
            surface = MachineSurface(
                items: {
                    let model = models.machines
                    return model.allMachines.map { machine in
                        .init(
                            id: machine.id, name: machine.name, detail: machine.subtitle,
                            connected: model.sessions[machine.id]?.state.isConnected ?? false)
                    }
                },
                open: { id in
                    let model = models.machines
                    guard model.knows(id) else { return }
                    model.selection = id

                }, stopped: { [weak self] in self?.running != true },
                health: { [weak self] in
                    guard let health = self?.health else { return nil }
                    if let latest = health.latest,
                        Date().timeIntervalSince(latest.checkedAt) < 60
                    {
                        return latest
                    }
                    return await health.refresh()
                })
            let files = MachineFilesEngine(
                session: { id in
                    guard models.machines.knows(id) else {
                        throw MachineUIError.invalidRequest
                    }
                    return models.machines.session(for: id)
                },
                makeModel: { session, path in
                    FinderModel(
                        session: session, path: path,
                        peerSession: { models.machines.sessions[$0] })
                }, onRelease: { FinderUndoBridge.forget($0) })
            filesEngine = files
            let previews = MachinePreviewEngine(session: { id in
                guard models.machines.knows(id) else {
                    throw MachineUIError.invalidRequest
                }
                return models.machines.session(for: id)
            })
            previewEngine = previews
            let directoryExport = MachineDirectoryExport(session: { id in
                guard models.machines.knows(id) else {
                    throw MachineUIError.invalidRequest
                }
                return models.machines.session(for: id)
            })
            self.directoryExport = directoryExport
            let logs = MachineLogEngine(session: { id in
                guard models.machines.knows(id) else {
                    throw MachineUIError.invalidRequest
                }
                return models.machines.session(for: id)
            })
            logEngine = logs
            let terminals = MachineTerminalEngine(session: { id in
                guard models.machines.knows(id) else {
                    throw MachineUIError.invalidRequest
                }
                return models.machines.session(for: id)
            })
            terminalEngine = terminals
            MachinesCLIEnvironment.interactive = { machine, arguments, environment in
                try await terminals.runCLI(
                    machine: machine, arguments: arguments, environment: environment)
            }
            MachinesCLIEnvironment.broadcast = { id, plan, requestID in
                try await terminals.broadcast(machineID: id, plan: plan, requestID: requestID)
            }
            MachinesCLIEnvironment.undo = { id in try await files.undo(machineID: id) }
            let windowNavigation = (input["hostNavigation"] as? NSObject).flatMap {
                MachineHostWindowNavigationClient(bridge: $0)
            }
            self.windowNavigation = windowNavigation
            uiEngine = MachineUIEngine(
                session: { id in
                    guard models.machines.knows(id) else {
                        throw MachineUIError.invalidRequest
                    }
                    return models.machines.session(for: id)
                },
                state: { models.state() },
                mutation: { value in
                    let model = models.machines
                    guard value.operation == .add || model.knows(value.machine.id) else {
                        throw MachineUIError.invalidRequest
                    }
                    MachineMutationOperationExecution.perform(
                        value.operation, machine: value.machine, secrets: value.secrets,
                        notify: { model.reloadOwnedRecords() })
                    if value.operation != .add {
                        await model.sessions[value.machine.id]?.shutdown()
                    }
                },
                workspace: { value in
                    try WorkspaceStore.save(value)
                    models.workspace.store = value
                    if let current = value.current { models.workspace.layout = current }
                },
                paneAdmission: { terminals.admitsPaneAction($0, workspaceTabID: $1) },
                observe: { _, active in
                    if active, !fixture { models.machines.reconcileSSHClipboards() }
                }, files: { value in try await files.execute(value) },
                openWindow: { request in
                    guard let windowNavigation else {
                        throw MachineUIFailure(
                            message: "The owning app window bridge is unavailable.")
                    }
                    try await windowNavigation.open(request)
                },
                directoryExport: { value in try await directoryExport.execute(value) },
                preview: { value in try await previews.execute(value) },
                logs: { value in try logs.execute(value) },
                fileProgress: { value in try files.progress(value) },
                presentationRelease: { id in
                    files.release(id); terminals.release(id); logs.release(id)
                },
                terminal: { value in try await terminals.execute(value) })
            do {
                cli = try MachineCLIService(runner: { machine, owner in
                    let session = models.machines.session(for: machine.id)
                    return RemoteRunner(
                        machine: machine, connection: session.connectionRef, owner: owner,
                        connect: { try await session.connectForCommand() },
                        disconnect: { await session.shutdown() })
                })
            } catch { return false }
            MachinesCLIEnvironment.changed = { models.machines.reloadOwnedRecords() }
            if !fixture {
                let policy = ambientPolicy
                let health = MachineHealthLifecycle(interval: {
                    policy.interval(for: MachineHealthLifecycle.jobID)
                })
                self.health = health
                health.start()
            }
            MachinePrivacy.shared.start()
            TextEditingCommands.install()
            running = true
        }
        return true
    }

    func synchronize(_ context: ExtensionHostContext) -> Bool {
        do { _ = try fixtureAdmission(context.input) } catch { return false }
        do { try ambientPolicy.apply(context: context.input) } catch { return false }
        return true
    }

    func configureUI(_ configuration: ExtensionUIConfiguration) -> Bool {
        guard uiClient == nil, !running, let client = configuration.engineClient else {
            return false
        }
        let facade = MachineUIClient(client: client)
        let model = MachinesModel(uiClient: facade)
        MachinesModel.shared = model
        let workspace = WorkspaceModel(machines: model)
        uiMachines = model
        uiWorkspace = workspace
        WorkspaceModel.shared = workspace
        MachineUIPresentations.register(model, workspace: workspace)
        facade.receive = { [weak model, weak workspace] state in
            model?.applyUIState(state)
            workspace?.applyUIState(state.workspaces)
        }
        facade.failure = { [weak model] message in model?.operationError = message }
        uiClient = facade
        facade.start()
        MachinePrivacy.shared.start()
        TextEditingCommands.install()
        MachineWindowCommands.shared.install()
        return true
    }

    func view(for presentation: UUID, context: ExtensionHostContext) -> NSViewController? {
        guard uiClient != nil, let model = uiMachines, let workspace = uiWorkspace else {
            return nil
        }
        if context.input["location"] as? String == "machines.window" {
            guard let target = context.input["target"] as? NSDictionary,
                let bytes = try? JSONSerialization.data(withJSONObject: target),
                let request = try? JSONDecoder().decode(
                    MachineHostWindowRequest.self, from: bytes),
                (try? request.validate()) != nil
            else { return nil }
            return NSHostingController(
                rootView: ExtensionPageHost {
                    MachinesHostWindowPage(request: request, model: model)
                        .environment(\.machineConnectionsEnabled, true)
                        .environment(\.terminalLaunchEnabled, true)
                })
        }
        return NSHostingController(
            rootView: ExtensionPageHost {
                MachinesPage(model: model, workspace: workspace).environment(
                    \.machineConnectionsEnabled, true
                )
                .environment(\.terminalLaunchEnabled, true)
            })
    }

    func perform(_ operation: String, context: NSDictionary) -> NSObject? {
        switch operation {
        case "terminalUI":
            guard let facade = uiClient, let data = context["payload"] as? Data,
                let value = context["presentationID"] as? String,
                UUID(uuidString: value) == facade.terminalUI.presentationID,
                let ok = try? facade.terminalUI.accept(data)
            else { return nil }
            return ["ok": ok] as NSDictionary
        case "terminalUIStatus":
            guard let facade = uiClient, let value = context["presentationID"] as? String,
                UUID(uuidString: value) == facade.terminalUI.presentationID
            else { return nil }
            return [
                "ok": true, "presentationID": facade.terminalUI.presentationID.uuidString,
                "focused": facade.terminalUI.focused,
            ] as NSDictionary
        default: return nil
        }
    }

    func stopUI(for presentation: UUID?) -> [Task<Void, Never>] {
        ExtensionUIResources.cleanup(of: runtime, key: "paneActions") {
            self.uiWorkspace?.stopPaneActions()
            MachineProcessModels.reset()
        }
        let retirement = retireUI()
        ExtensionUIResources.cleanup(of: runtime, key: "paneViews") {
            FinderUndoBridge.shutdown()
            PaneViewStore.shared.shutdown()
        }
        return retirement.map { [$0] } ?? []
    }

    func cancelPendingWork() {
        let work = SuspendedWork(
            facade: uiClient, cli: cli, terminals: terminalEngine, ui: uiEngine,
            previews: previewEngine, exports: directoryExport, logs: logEngine,
            files: filesEngine, peer: peer)
        suspendedWork = work
        work.facade?.cancelPendingWork()
        work.cli?.cancelPendingWork()
        work.terminals?.cancelPendingWork()
        work.ui?.cancelPendingWork()
        work.previews?.cancelPendingWork()
        work.exports?.cancelPendingWork()
        work.logs?.cancelPendingWork()
        work.files?.shutdown()
        work.peer?.shutdown()
    }

    func drain() async {
        guard let work = suspendedWork else { return }
        await work.facade?.drain()
        await work.cli?.drain()
        await work.terminals?.drain()
        await work.ui?.drain()
        await work.previews?.drain()
        await work.exports?.drain()
        await work.logs?.drain()
        await work.files?.shutdownAndWait()
        await work.peer?.shutdownAndWait()
    }

    func finishBeforeStop() async {
        running = false
    }

    func teardown() async {
        await shutdown()
        retireUI()
        for task in Array(uiRetirements.values) { await task.value }
    }

    @discardableResult
    private func retireUI() -> Task<Void, Never>? {
        guard let facade = uiClient else { return nil }
        ExtensionUIResources.cleanup(of: runtime, key: "machinePrivacy") {
            MachinePrivacy.shared.shutdown()
        }
        ExtensionUIResources.cleanup(of: runtime, key: "textEditing") {
            TextEditingCommands.shutdown()
        }
        ExtensionUIResources.cleanup(of: runtime, key: "machineWindows") {
            MachineWindowCommands.shared.shutdown()
        }
        let machines = uiMachines
        let workspace = uiWorkspace
        uiMachines = nil
        uiWorkspace = nil
        if let machines { MachineUIPresentations.release(machines) }
        workspace?.stopPaneActions()
        facade.cancelPendingWork()
        let id = UUID()
        let task = Task { [self, facade] in
            await facade.drain()
            await workspace?.shutdown()
            await machines?.shutdown()
            facade.shutdown()
            uiRetirements[id] = nil
        }
        uiRetirements[id] = task
        uiClient = nil
        return task
    }

    private func shutdown() async {
        running = false
        guard let engineModels else { return }
        ambientPolicy.stop()
        windowNavigation?.invalidate(); windowNavigation = nil
        await uiEngine?.shutdown(); uiEngine = nil
        await filesEngine?.shutdownAndWait(); filesEngine = nil
        await previewEngine?.drain()
        previewEngine?.shutdown(); previewEngine = nil
        await directoryExport?.drain()
        directoryExport?.shutdown(); directoryExport = nil
        await logEngine?.shutdown(); logEngine = nil
        await terminalEngine?.shutdown(); terminalEngine = nil
        MachinesCLIEnvironment.broadcast = { _, _, _ in throw MachineUIError.unavailable }
        MachinesCLIEnvironment.interactive = { _, _, _ in throw MachineUIError.unavailable }
        MachinesCLIEnvironment.undo = { _ in throw MachineUIError.unavailable }
        await health?.stop(); health = nil
        await cli?.shutdown(); cli = nil
        MachinesCLIEnvironment.changed = {}
        await peer?.shutdownAndWait()
        FinderUndoBridge.shutdown()
        PaneViewStore.shared.shutdown()
        await engineModels.shutdown()
        self.engineModels = nil
        await transport?.shutdown()
        transport = nil; peer = nil; surface = nil
        ExtensionUIResources.cleanup(of: runtime, key: "machinePrivacy") {
            MachinePrivacy.shared.shutdown()
        }
        ExtensionUIResources.cleanup(of: runtime, key: "textEditing") {
            TextEditingCommands.shutdown()
        }
    }
}

@MainActor
func makeMachinesRuntime(
    fixtureAdmission: ((NSDictionary) throws -> WorkerFixtureAdmission?)? = nil
) -> ExtensionServiceRuntime {
    final class BundleAnchor {}
    return ExtensionServiceRuntime(
        id: "machines", role: "app", bundle: Bundle(for: BundleAnchor.self)
    ) { runtime in
        guard let fixtureAdmission else { return MachinesService(runtime: runtime) }
        return MachinesService(runtime: runtime, fixtureAdmission: fixtureAdmission)
    }
}

@_cdecl("edith_extension_create")
public func createExtension() -> UnsafeMutableRawPointer? {
    UnsafeMutableRawPointer(
        bitPattern: MainActor.assumeIsolated {
            UInt(bitPattern: Unmanaged.passRetained(makeMachinesRuntime()).toOpaque())
        })
}

@MainActor
private enum MachineUIPresentations {
    private struct Models {
        weak var machines: MachinesModel?
        weak var workspace: WorkspaceModel?
    }
    private static var active: [Models] = []

    static func register(_ machines: MachinesModel, workspace: WorkspaceModel) {
        active.removeAll { $0.machines == nil || $0.machines === machines }
        active.append(Models(machines: machines, workspace: workspace))
    }

    static func release(_ machines: MachinesModel) {
        active.removeAll { $0.machines == nil || $0.machines === machines }
        if let remaining = active.last, let model = remaining.machines,
            let workspace = remaining.workspace
        {
            MachinesModel.shared = model
            WorkspaceModel.shared = workspace
        }
    }
}
