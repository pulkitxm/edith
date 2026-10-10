import AppKit
import EdithExtensionCommands
import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import SwiftUI
#if canImport(WorkerFixtureSupport)
import WorkerFixtureSupport
#endif

@MainActor @objc(EdithUsageExtensionRuntime)
final class ExtensionRuntime: NSObject {
    private var controller: UsageWorkerController?
    private var usageStore: UsageStore?
    private var surface: UsageSurface?
    private var statusLine: UsageStatusLineCommands?
    private var statusLineConnectionTask: Task<Void, Never>?
    private var recovering = false
    private var reports: UsageReportCommands?
    private var machinesProjection: UsageMachinesProjection?
    private var alerts: UsageLimitAlerts?
    private var alertsTask: Task<Void, Never>?
    private var backup: UsageBackupProvider?
    private var backupRestoreTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private let commands = ExtensionCommandRegistry()
    private var cliHooks: UsageCLIHookOwner?
    private var cliStreams: ExtensionCLIStreams?
    private var uiCommands: UsageUICommands?
    private var navigation: UsageHostNavigation?
    private let uiPresentations = UsageUIPresentations()

    private let admitFixture: (NSDictionary) throws -> WorkerFixtureAdmission?

    override convenience init() {
        self.init(admitFixture: {
            try WorkerFixtureAdmission.current(
                extensionID: "usage", context: $0, roleBundle: Bundle(for: ExtensionRuntime.self))
        })
    }

    init(admitFixture: @escaping (NSDictionary) throws -> WorkerFixtureAdmission?) {
        self.admitFixture = admitFixture
        super.init()
    }

    @objc func invoke(_ request: NSDictionary, completion: @escaping (NSData?, NSString?) -> Void) {
        commands.invoke(request, completion: completion) { [weak self] command, payload in
            guard let self, self.controller != nil else { throw ExtensionPeerError.unavailable }
            if command == "usage.cli.catalog" { return try UsageCLIProvider.catalog() }
            if command == "usage.cli.complete" { return try UsageCLIProvider.complete(payload) }
            if command == "usage.config.cli", let controller = self.controller {
                let request = try JSONDecoder().decode(ExtensionCLIRequest.self, from: payload)
                try request.validate()
                let resources = UsageCLIResources(controller: controller)
                let reply = try await UsageCLIEnvironment.$resources.withValue(resources) {
                    try await ExtensionCLIExecution.run(UsageConfigCommand.self, request: request)
                }
                return try JSONEncoder().encode(reply)
            }
            if command.hasPrefix("usage.cli"), let controller = self.controller {
                let forget: @MainActor (UUID) async throws -> Void = { id in
                    guard let projection = self.machinesProjection else {
                        throw ExtensionPeerError.unavailable
                    }
                    try await projection.forget(machineID: id)
                }
                if command == "usage.cli" {
                    let request = try JSONDecoder().decode(ExtensionCLIRequest.self, from: payload)
                    let reply = try await UsageCLIExecution.run(
                        request, controller: controller, hookOwner: self.cliHooks,
                        forgetMachine: forget)
                    return try JSONEncoder().encode(reply)
                }
                guard let streams = self.cliStreams else { throw ExtensionPeerError.unavailable }
                let resources = UsageCLIResources(
                    controller: controller, hookOwner: self.cliHooks, forgetMachine: forget)
                return try UsageCLIEnvironment.$resources.withValue(resources) {
                    try streams.invoke(
                        UsageCommand.self, operation: command,
                        prefix: "usage.cli", payload: payload)
                }
            }
            if command.hasPrefix("usage.ui."), let uiCommands = self.uiCommands {
                return try await uiCommands.execute(command, payload: payload)
            }
            if command.hasPrefix("surface."), let surface = self.surface {
                return try await surface.execute(command, payload: payload)
            }
            if command.hasPrefix("usage.statusline."), let statusLine = self.statusLine {
                return try await statusLine.execute(command, payload: payload)
            }
            if command.hasPrefix("backup."), let backup = self.backup {
                if command == "backup.synchronize" { await self.backupRestoreTask?.value }
                try Task.checkCancellation()
                return try await backup.execute(command, payload: payload)
            }
            if ["usage.machines.project", "usage.machines.result", "usage.machines.cancel"]
                .contains(command),
                let projection = self.machinesProjection
            {
                return try await projection.execute(command, payload: payload)
            }
            guard let reports = self.reports else { throw ExtensionPeerError.unavailable }
            return try await reports.execute(command, payload: payload)
        }
    }

    @objc(prepareDisableWithCompletion:)
    func prepareDisable(completion: @escaping (NSError?) -> Void) {
        uiPresentations.stop()
        UsageWorkerOperations.statusLineCommands = nil
        cliStreams?.stop()
        commands.shutdown()
        statusLineConnectionTask?.cancel()
        Task {
            await uiPresentations.stopAndWait()
            await commands.shutdownAndWait()
            await cliStreams?.stopAndWait()
            await statusLineConnectionTask?.value
            do {
                try cliHooks?.shutdown()
                try await statusLine?.shutdown()
                completion(nil)
            } catch { completion(error as NSError) }
        }
    }

    @objc(prepareToStopWithCompletion:)
    func prepareToStop(completion: @escaping () -> Void) {
        uiPresentations.stop()
        cliStreams?.stop()
        commands.shutdown()
        let uiCommands = uiCommands; self.uiCommands = nil
        uiCommands?.shutdown()
        let navigation = navigation; self.navigation = nil
        navigation?.invalidate()
        controller?.beginShutdown()
        alertsTask?.cancel()
        backupRestoreTask?.cancel()
        for observer in observers { UsageEvents.stopObserving(observer) }
        observers = []
        usageStore?.shutdown()
        DashboardModel.shared.shutdown()
        UsagePresenterState.shared.shutdown()
        UsageWorkerOperations.controller = nil
        UsageWorkerOperations.statusLineCommands = nil
        UsageWorkerOperations.machinesProjection = nil
        let controller = controller; self.controller = nil
        let alerts = alerts; self.alerts = nil
        let task = alertsTask; alertsTask = nil
        let reports = reports; self.reports = nil
        let projection = machinesProjection; machinesProjection = nil
        let statusLine = self.statusLine; self.statusLine = nil
        let cliHooks = self.cliHooks; self.cliHooks = nil
        let cliStreams = self.cliStreams; self.cliStreams = nil
        let connectionTask = statusLineConnectionTask; statusLineConnectionTask = nil
        let backup = self.backup; self.backup = nil
        let backupRestoreTask = self.backupRestoreTask; self.backupRestoreTask = nil
        connectionTask?.cancel()
        recovering = false
        surface = nil; usageStore = nil
        Task {
            await uiPresentations.stopAndWait()
            await backup?.shutdown()
            await backupRestoreTask?.value
            await commands.shutdownAndWait()
            await navigation?.stopAndWait()
            await uiCommands?.shutdownAndWait()
            await cliStreams?.stopAndWait()
            await connectionTask?.value
            try? cliHooks?.shutdown()
            try? await statusLine?.shutdown()
            await controller?.shutdown()
            await task?.value
            await alerts?.shutdown()
            await reports?.shutdown()
            await projection?.shutdown()
            if UsageExecutionEnvironment.fixtureHome == nil {
                await UsageLimitAlerts.removePending()
                LimitNotifier.shared.shutdown()
            }
            completion()
        }
    }

    @objc(prepareUIToClose:completion:)
    func prepareUIToClose(_ presentationID: NSString, completion: @escaping (NSString?) -> Void) {
        guard let id = UUID(uuidString: presentationID as String),
            let scene = uiPresentations.scenes[id]
        else {
            completion("Usage presentation is unavailable."); return
        }
        Task {
            await scene.shutdownAndWait(); completion(nil)
        }
    }

    @objc func execute(_ input: NSDictionary) -> NSObject {
        switch input["operation"] as? String {
        case "describe":
            let bundle = Bundle(for: ExtensionRuntime.self)
            return [
                "id": "usage", "role": "app",
                "version": bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                    as? String ?? "",
                "hostABI": bundle.object(forInfoDictionaryKey: "EdithHostABI") as? String ?? "",
            ] as NSDictionary
        case "configureUI":
            uiPresentations.prune()
            guard controller == nil, !recovering,
                let configuration = ExtensionUIConfiguration(context: input),
                configuration.extensionID == "usage",
                let text = input["presentationID"] as? String, let id = UUID(uuidString: text),
                let route = UsageUISceneRoute(context: input),
                !configuration.uiOnly || route.location == .settings
            else { return ["ok": false] as NSDictionary }
            if let existing = uiPresentations.scenes[id] {
                return ["ok": existing.matches(input)] as NSDictionary
            }
            let scene = UsageUIPresentation(
                id: id, route: route,
                client: configuration.engineClient.map { UsageUIClient(client: $0) },
                readOnly: configuration.uiOnly)
            if !uiPresentations.configure(scene) {
                scene.shutdown(); return ["ok": false] as NSDictionary
            }
        case "releaseUI":
            guard let text = input["presentationID"] as? String, let id = UUID(uuidString: text)
            else {
                return ["ok": false] as NSDictionary
            }
            uiPresentations.release(id)
        case "stopUI": uiPresentations.stop()
        case "start":
            guard Bundle.main.bundleURL.pathExtension != "appex", uiPresentations.isEmpty else {
                return ["ok": false] as NSDictionary
            }
            guard let suite = input["defaultsSuite"] as? String,
                suite == ProcessInfo.processInfo.environment["EDITH_SHARED_DEFAULTS_SUITE"]
            else { return ["ok": false] as NSDictionary }
            let fixture: Bool
            do { fixture = try admitFixture(input) != nil } catch {
                return ["ok": false, "error": error.localizedDescription] as NSDictionary
            }
            guard controller == nil, !recovering else { return ["ok": true] as NSDictionary }
            let launcher = ClaudeStatusLine.publicExecutable(fromVerifiedContext: input)
            let statusLine = UsageStatusLineCommands(executable: launcher)
            self.statusLine = statusLine
            let cliHooks = UsageCLIHookOwner(executable: launcher)
            self.cliHooks = cliHooks
            if input["recoveryOnly"] as? Bool == true {
                recovering = true
                return ["ok": true] as NSDictionary
            }
            if !fixture {
                do { backup = try UsageBackupProvider.live() } catch {
                    return ["ok": false, "error": error.localizedDescription] as NSDictionary
                }
            }
            let controller = UsageWorkerController { policy, event in
                let local = try await UsageNativeCollector.collect(
                    home: UsageExecutionEnvironment.home, dataDirectory: Repo.dataDir,
                    environment: UsageExecutionEnvironment.collectorEnvironment(), onEvent: event)
                if fixture { return local }
                return try await UsageMachinesPeer.merge(
                    local: local, policy: policy, onEvent: event)
            }
            do {
                try controller.applyAmbientPolicy(context: input)
                cliStreams = try ExtensionCLIStreams(owner: "usage")
            } catch {
                return ["ok": false, "error": error.localizedDescription] as NSDictionary
            }
            self.controller = controller
            UsageWorkerOperations.controller = controller
            let navigation = UsageHostNavigation(bridge: input["hostNavigation"] as? NSObject)
            self.navigation = navigation
            uiCommands = UsageUICommands(
                controller: controller,
                navigate: { [weak navigation] request in
                    guard let navigation else { throw ExtensionPeerError.unavailable }
                    try await navigation.navigate(request)
                })
            let cache = SurfaceUsageStore(url: Repo.usageJSON)
            surface = UsageSurface(store: cache, controller: controller)
            UsageWorkerOperations.statusLineCommands = statusLine
            let projection = UsageMachinesProjection()
            machinesProjection = projection
            UsageWorkerOperations.machinesProjection = projection
            reports = UsageReportCommands(
                controller: controller, store: cache,
                forgetMachine: { try await projection.forget(machineID: $0) })
            usageStore = UsageStore(showMenuBar: !fixture)
            statusLineConnectionTask = Task {
                try? await statusLine.resumeOwnedHook()
                try? cliHooks.resumeOwnedHooks()
            }
            if !fixture {
                let alerts = UsageLimitAlerts(); self.alerts = alerts
                _ = LimitNotifier.shared
                observers.append(
                    UsageEvents.observe(UsageEvents.limitsUpdated) { [weak self] in
                        guard let self, let snapshot = self.controller?.latestLimits else { return }
                        self.alertsTask?.cancel()
                        self.alertsTask = Task { try? await alerts.evaluate(snapshot) }
                    })
                observers.append(
                    UsageEvents.observe(UserDefaults.didChangeNotification) { [weak self] in
                        self?.usageStore?.syncStatusItem(); self?.usageStore?.refreshMenuBarItem()
                    })
                let backup = self.backup
                backupRestoreTask = Task { [weak self, weak controller] in
                    let restored = await backup?.restoreOnEnable()
                    guard !Task.isCancelled, self?.controller === controller else { return }
                    backup?.startScheduling(restorePending: restored == false)
                    controller?.startBackgroundCollection()
                }
            }
        case "view":
            guard let text = input["presentationID"] as? String, let id = UUID(uuidString: text),
                let scene = uiPresentations.scenes[id], scene.matches(input)
            else { return ["ok": false] as NSDictionary }
            return scene.controller() ?? (["ok": false] as NSDictionary)
        case "cancelCommand": commands.cancel(input["token"] as? String ?? "")
        case "synchronize":
            do {
                _ = try admitFixture(input)
                guard let controller else { return ["ok": false] as NSDictionary }
                try controller.synchronizeAmbientPolicy(context: input) {
                    usageStore?.syncStatusItem(); usageStore?.refreshMenuBarItem()
                    backup?.preferencesChanged()
                }
            } catch {
                return ["ok": false, "error": error.localizedDescription] as NSDictionary
            }
        case "stop": prepareToStop(completion: {})
        case "status": return ["ok": true, "running": controller != nil] as NSDictionary
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
