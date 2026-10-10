import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import EdithExtensionCommands
import SwiftUI

@MainActor @objc(EdithMachinesExtensionRuntime)
final class ExtensionRuntime: NSObject {
    private var running = false
    private var peer: MachinePeerService?
    private var surface: MachineSurface?
    private var transport: MachinePeerTransport?
    private var cli: MachineCLIService?
    private var previewEngine: MachinePreviewEngine?
    private var filesEngine: MachineFilesEngine?
    private var logEngine: MachineLogEngine?
    private var terminalEngine: MachineTerminalEngine?
    private var uiEngine: MachineUIEngine?
    private var uiClient: MachineUIClient?
    private var health: MachineHealthLifecycle?
    private let commands = ExtensionCommandRegistry()

    @objc func invoke(_ request: NSDictionary, completion: @escaping (NSData?, NSString?) -> Void) {
        commands.invoke(request, completion: completion) { [weak self] command, payload in
            guard self?.running == true else { throw ExtensionPeerError.unavailable }
            guard let self else { throw ExtensionPeerError.unavailable }
            if command == "machines.cli.catalog" {
                guard payload == Data("{}".utf8) else { throw ExtensionPeerError.invalidRequest }
                return try MachineCLICatalog.encoded()
            }
            if command == "machines.cli.complete" { return try MachineCLICatalog.complete(payload) }
            if command.hasPrefix("machines.ui.") {
                guard let uiEngine = self.uiEngine else { throw ExtensionPeerError.unavailable }
                return try await uiEngine.execute(command, payload: payload)
            }
            if command.hasPrefix("machines.cli.pty.") {
                guard let terminals = self.terminalEngine else {
                    throw ExtensionPeerError.unavailable
                }
                return try terminals.cliInvoke(command, payload: payload)
            }
            if command.hasPrefix("machines.cli.stream.") {
                guard let cli = self.cli else { throw ExtensionPeerError.unavailable }
                return try cli.invoke(command, payload: payload)
            }
            if command == "machines.cli" {
                guard let cli = self.cli else { throw ExtensionPeerError.unavailable }
                let request = try JSONDecoder().decode(ExtensionCLIRequest.self, from: payload)
                return try JSONEncoder().encode(try await cli.execute(request))
            }
            if command == "machines.health.snapshot" {
                guard payload == Data("{}".utf8), let health = self.health?.latest else {
                    throw ExtensionPeerError.unavailable
                }
                return try JSONEncoder().encode(health)
            }
            if command.hasPrefix("machines.usage.snapshot.") {
                guard let transport = self.transport else { throw ExtensionPeerError.unavailable }
                return try transport.snapshots.execute(command, payload: payload)
            }
            if command.hasPrefix("surface.") {
                guard let surface = self.surface else { throw ExtensionPeerError.unavailable }
                return try await surface.execute(command, payload: payload)
            }
            guard let peer = self.peer else { throw ExtensionPeerError.unavailable }
            return try await peer.execute(command, payload: payload)
        }
    }

    @objc(prepareToStopWithCompletion:)
    func prepareToStop(completion: @escaping () -> Void) {
        commands.shutdown()
        running = false
        Task {
            await shutdown()
            completion()
        }
    }

    @objc func execute(_ input: NSDictionary) -> NSObject {
        switch input["operation"] as? String {
        case "describe":
            let bundle = Bundle(for: ExtensionRuntime.self)
            return [
                "id": "machines", "role": "app",
                "version": bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                    as? String ?? "",
                "hostABI": bundle.object(forInfoDictionaryKey: "EdithHostABI") as? String ?? "",
            ] as NSDictionary
        case "configureUI":
            guard uiClient == nil, !running,
                let configuration = ExtensionUIConfiguration(context: input),
                configuration.extensionID == "machines", let client = configuration.engineClient
            else { return ["ok": false] as NSDictionary }
            let facade = MachineUIClient(client: client)
            let model = MachinesModel(uiClient: facade)
            MachinesModel.shared = model
            let workspace = WorkspaceModel(machines: model)
            WorkspaceModel.shared = workspace
            facade.receive = { [weak model, weak workspace] state in
                model?.applyUIState(state)
                workspace?.applyUIState(state.workspaces)
            }
            facade.failure = { [weak model] message in model?.operationError = message }
            uiClient = facade
            facade.start()
            return ["ok": true] as NSDictionary
        case "stopUI":
            uiClient?.shutdown(); uiClient = nil
            FinderUndoBridge.shutdown()
            PaneViewStore.shared.shutdown()
            return ["ok": true] as NSDictionary
        case "start":
            guard uiClient == nil, Bundle.main.bundleURL.pathExtension != "appex" else {
                return ["ok": false] as NSDictionary
            }
            guard let suite = input["defaultsSuite"] as? String,
                suite == ProcessInfo.processInfo.environment["EDITH_SHARED_DEFAULTS_SUITE"]
            else { return ["ok": false] as NSDictionary }
            if !running {
                MachinesModel.shared = MachinesModel()
                WorkspaceModel.shared = WorkspaceModel(machines: .shared)
                let fixture =
                    ProcessInfo.processInfo.environment["EDITH_EXTENSION_FIXTURE_HOME"] != nil
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
                        let model = MachinesModel.shared
                        return model.allMachines.map { machine in
                            .init(
                                id: machine.id, name: machine.name, detail: machine.subtitle,
                                connected: model.sessions[machine.id]?.state.isConnected ?? false)
                        }
                    },
                    open: { id in
                        let model = MachinesModel.shared
                        guard model.knows(id) else { return }
                        model.selection = id

                    }, stopped: { [weak self] in self?.running != true })
                let files = MachineFilesEngine(session: { id in
                    guard MachinesModel.shared.knows(id) else {
                        throw MachineUIError.invalidRequest
                    }
                    return MachinesModel.shared.session(for: id)
                })
                filesEngine = files
                let previews = MachinePreviewEngine(session: { id in
                    guard MachinesModel.shared.knows(id) else {
                        throw MachineUIError.invalidRequest
                    }
                    return MachinesModel.shared.session(for: id)
                })
                previewEngine = previews
                let logs = MachineLogEngine(session: { id in
                    guard MachinesModel.shared.knows(id) else {
                        throw MachineUIError.invalidRequest
                    }
                    return MachinesModel.shared.session(for: id)
                })
                logEngine = logs
                let terminals = MachineTerminalEngine(session: { id in
                    guard MachinesModel.shared.knows(id) else {
                        throw MachineUIError.invalidRequest
                    }
                    return MachinesModel.shared.session(for: id)
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
                uiEngine = MachineUIEngine(
                    session: { id in
                        guard MachinesModel.shared.knows(id) else {
                            throw MachineUIError.invalidRequest
                        }
                        return MachinesModel.shared.session(for: id)
                    },
                    state: {
                        let model = MachinesModel.shared
                        model.reloadOwnedRecords()
                        return MachineUIState(
                            machines: model.store.machines, forwards: model.store.forwards,
                            snippets: model.store.snippets,
                            sessions: model.allMachines.map { model.session(for: $0.id).uiState() },
                            workspaces: WorkspaceStore.load(),
                            clipboardStates: model.sshClipboardStates)
                    },
                    mutation: { value in
                        let model = MachinesModel.shared
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
                        WorkspaceModel.shared.store = value
                        if let current = value.current { WorkspaceModel.shared.layout = current }
                    },
                    observe: { _, active in
                        if active, !fixture { MachinesModel.shared.reconcileSSHClipboards() }
                    }, files: { value in try await files.execute(value) },
                    preview: { value in try await previews.execute(value) },
                    logs: { value in try logs.execute(value) },
                    terminal: { value in try await terminals.execute(value) })
                do {
                    cli = try MachineCLIService(runner: { machine, owner in
                        let session = MachinesModel.shared.session(for: machine.id)
                        return RemoteRunner(
                            machine: machine, connection: session.connectionRef, owner: owner,
                            connect: { try await session.connectForCommand() },
                            disconnect: { await session.shutdown() })
                    })
                } catch { return ["ok": false] as NSDictionary }
                MachinesCLIEnvironment.changed = { MachinesModel.shared.reloadOwnedRecords() }
                if !fixture {
                    let health = MachineHealthLifecycle()
                    self.health = health
                    health.start()
                }
                MachinePrivacy.shared.start()
                TextEditingCommands.install()
                running = true
            }
        case "view":
            guard uiClient != nil else { return ["ok": false] as NSDictionary }
            return NSHostingController(
                rootView: ExtensionPageHost {
                    MachinesPage().environment(\.machineConnectionsEnabled, true)
                        .environment(\.terminalLaunchEnabled, true)
                })
        case "cancelCommand": commands.cancel(input["token"] as? String ?? "")
        case "stop":
            commands.shutdown()
            running = false
            Task { await shutdown() }
        case "status": return ["ok": true, "running": running] as NSDictionary
        default: return ["ok": false] as NSDictionary
        }
        return ["ok": true] as NSDictionary
    }
    private func shutdown() async {
        running = false
        await uiEngine?.shutdown(); uiEngine = nil
        filesEngine?.shutdown(); filesEngine = nil
        previewEngine?.shutdown(); previewEngine = nil
        await logEngine?.shutdown(); logEngine = nil
        await terminalEngine?.shutdown(); terminalEngine = nil
        MachinesCLIEnvironment.broadcast = { _, _, _ in throw MachineUIError.unavailable }
        MachinesCLIEnvironment.interactive = { _, _, _ in throw MachineUIError.unavailable }
        MachinesCLIEnvironment.undo = { _ in throw MachineUIError.unavailable }
        await commands.shutdownAndWait()
        await health?.stop(); health = nil
        await cli?.shutdown(); cli = nil
        MachinesCLIEnvironment.changed = {}
        peer?.shutdown()
        FinderUndoBridge.shutdown()
        PaneViewStore.shared.shutdown()
        MachineWindow.shutdown(); FinderWindow.shutdown(); DockerWindow.shutdown();
        TerminalWindow.shutdown()
        await WorkspaceModel.shared.shutdown()
        await MachinesModel.shared.shutdown()
        await transport?.shutdown()
        transport = nil; peer = nil; surface = nil
        MachinePrivacy.shared.shutdown()
        TextEditingCommands.shutdown()
    }

}

@_cdecl("edith_extension_create")
public func createExtension() -> UnsafeMutableRawPointer? {
    MainActor.assumeIsolated { Unmanaged.passRetained(ExtensionRuntime()).toOpaque() }
}
