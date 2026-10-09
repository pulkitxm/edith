import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

@MainActor @objc(EdithMachinesExtensionRuntime)
final class ExtensionRuntime: NSObject {
    private var running = false
    private var peer: MachinePeerService?
    private var surface: MachineSurface?
    private var transport: MachinePeerTransport?
    private let commands = ExtensionCommandRegistry()

    @objc func invoke(_ request: NSDictionary, completion: @escaping (NSData?, NSString?) -> Void) {
        commands.invoke(request, completion: completion) { [weak self] command, payload in
            guard self?.running == true else { throw ExtensionPeerError.unavailable }
            guard let self else { throw ExtensionPeerError.unavailable }
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
        case "start":
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
                        MachineWindow.open(
                            machineID: id, title: model.session(for: id).machine.name)
                    }, stopped: { [weak self] in self?.running != true })
                MachinePrivacy.shared.start()
                MachineTerminalBroadcastBridge.install()
                TextEditingCommands.install()
                running = true
            }
        case "view":
            guard running else { return ["ok": false] as NSDictionary }
            let fixture = ProcessInfo.processInfo.environment["EDITH_EXTENSION_FIXTURE_HOME"] != nil
            return NSHostingController(
                rootView: ExtensionPageHost {
                    MachinesPage().environment(\.machineConnectionsEnabled, true)
                        .environment(\.terminalLaunchEnabled, !fixture)
                })
        case "cancelCommand": commands.cancel(input["token"] as? String ?? "")
        case "stop":
            commands.shutdown()
            running = false
            peer?.shutdown()
            peer = nil; surface = nil
            MachinesModel.shared.stopAll()
            MachineTerminalBroadcastBridge.shutdown()
            MachinePrivacy.shared.shutdown()
            TextEditingCommands.shutdown()
        case "status": return ["ok": true, "running": running] as NSDictionary
        default: return ["ok": false] as NSDictionary
        }
        return ["ok": true] as NSDictionary
    }
    private func shutdown() async {
        running = false
        peer?.shutdown()
        MachineTerminalBroadcastBridge.shutdown()
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
