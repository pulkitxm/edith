import AppKit
import EdithExtensionSupport
import EdithExtensionCommands
import EdithExtensionUI
import SwiftUI

@MainActor @objc(EdithCompanionExtensionRuntime)
final class ExtensionRuntime: NSObject {
    private let ambientPolicy = ExtensionAmbientPolicy(jobs: [
        CompanionMonitor.jobID: .init(ambient: 60, live: 20)
    ])
    private var worker: CompanionWorker?
    private var uiWorkspace: CompanionWorkspaceSession?
    private var uiEngine: CompanionUIEngine?
    private var engineClient: ExtensionEngineClient?
    private var surface: CompanionSurface?
    private let commands = ExtensionCommandRegistry()
    private var cliStreams: ExtensionCLIStreams?

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

    @objc(prepareToStopWithCompletion:)
    func prepareToStop(completion: @escaping () -> Void) {
        ambientPolicy.stop()
        let streams = cliStreams; cliStreams = nil; streams?.stop()
        _ = CompanionCLIExecution.stopChats()
        commands.shutdown()
        let engine = uiEngine; uiEngine = nil
        let worker = worker
        Task {
            await engine?.shutdown()
            await worker?.shutdown()
            await streams?.stopAndWait()
            await commands.shutdownAndWait()
            completion()
        }
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
            guard engineClient == nil, let configuration = ExtensionUIConfiguration(context: input),
                configuration.extensionID == "companion", let client = configuration.engineClient
            else { return ["ok": false] as NSDictionary }
            engineClient = client
            let bridge = CompanionUIBridge(client: client)
            CompanionTransport.shared.configureRemote(bridge)
            uiWorkspace = CompanionWorkspaceSession(remote: bridge)
            TextEditingCommands.install()
        case "stopUI":
            uiWorkspace?.shutdown(); uiWorkspace = nil
            CompanionTransport.shared.configureRemote(nil)
            engineClient?.invalidate(); engineClient = nil
            TextEditingCommands.shutdown()
        case "start":
            guard let suite = input["defaultsSuite"] as? String,
                suite == ProcessInfo.processInfo.environment["EDITH_SHARED_DEFAULTS_SUITE"]
            else { return ["ok": false] as NSDictionary }
            do { try ambientPolicy.apply(context: input) } catch {
                return ["ok": false] as NSDictionary
            }
            guard worker == nil else { return ["ok": true] as NSDictionary }
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
            if ProcessInfo.processInfo.environment["EDITH_EXTENSION_FIXTURE_HOME"] == nil {
                do { try policy.start { [weak monitor] in monitor?.reschedule() } } catch {
                    return ["ok": false] as NSDictionary
                }
            }
            worker.start()
            TextEditingCommands.install()
        case "view":
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
            do { try ambientPolicy.apply(context: input) } catch {
                return ["ok": false] as NSDictionary
            }
            IPC.post(IPC.Name.settingsChanged)
        case "stop":
            ambientPolicy.stop()
            _ = CompanionCLIExecution.stopChats()
            let streams = cliStreams; cliStreams = nil; streams?.stop()
            Task { await streams?.stopAndWait() }
            commands.shutdown()
            let engine = uiEngine; uiEngine = nil
            let worker = worker
            self.worker = nil
            surface = nil
            TextEditingCommands.shutdown()
            Task {
                await engine?.shutdown(); await worker?.shutdown()
            }
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
