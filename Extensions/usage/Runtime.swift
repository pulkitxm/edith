import AppKit
import EdithExtensionCommands
import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import SwiftUI
#if canImport(WorkerFixtureSupport)
import WorkerFixtureSupport
#endif

@MainActor
final class UsageService: ExtensionService {
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
    private var alertTasks: [UUID: Task<Void, Never>] = [:]
    private var draining = false
    private var backup: UsageBackupProvider?
    private var backupRestoreTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var drainTask: Task<Void, Never>?
    private var cliHooks: UsageCLIHookOwner?
    private var cliStreams: ExtensionCLIStreams?
    private var uiCommands: UsageUICommands?
    private var navigation: UsageHostNavigation?
    private let uiPresentations = UsageUIPresentations()

    private let admitFixture: (NSDictionary) throws -> WorkerFixtureAdmission?

    init(admitFixture: ((NSDictionary) throws -> WorkerFixtureAdmission?)? = nil) {
        self.admitFixture =
            admitFixture ?? {
                try WorkerFixtureAdmission.current(
                    extensionID: "usage", context: $0, roleBundle: Bundle(for: UsageService.self))
            }
    }

    func invoke(_ command: String, payload: Data) async throws -> Data {
        guard self.controller != nil else { throw ExtensionPeerError.unavailable }
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
            controller.demandIndex()
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
            return try await UsageCLIEnvironment.$resources.withValue(resources) {
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

    var preparesForDisable: Bool { true }
    var preparesUIToClose: Bool { true }
    var allowsUIDuringRetirement: Bool { true }
    var isRunning: Bool { controller != nil }

    func cancelPendingWork() {
        guard drainTask == nil else { return }
        draining = true
        let controller = controller, uiCommands = uiCommands, projection = machinesProjection
        let reports = reports, statusLine = statusLine, streams = cliStreams, backup = backup
        let restore = backupRestoreTask, connection = statusLineConnectionTask
        let alerts = Array(alertTasks.values)
        controller?.beginShutdown()
        uiCommands?.shutdown()
        streams?.stop()
        restore?.cancel()
        backup?.beginSuspension()
        connection?.cancel()
        for task in alerts { task.cancel() }
        drainTask = Task {
            [
                controller, uiCommands, projection, reports, statusLine, streams, backup,
                restore, connection, alerts
            ] in
            await projection?.beginSuspension()
            await reports?.beginSuspension()
            await statusLine?.beginSuspension()
            await backup?.shutdown()
            await controller?.suspendAndWait()
            await uiCommands?.shutdownAndWait()
            await projection?.suspendAndWait()
            await reports?.suspendAndWait()
            await statusLine?.suspendAndWait()
            await streams?.stopAndWait()
            await restore?.value
            await connection?.value
            for task in alerts { await task.value }
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }

    func drain() async { await drainTask?.value }

    func prepareDisable() async throws {
        uiPresentations.stop()
        UsageWorkerOperations.statusLineCommands = nil
        await uiPresentations.stopAndWait()
        try cliHooks?.shutdown()
        try await statusLine?.shutdown()
    }

    func teardown() async {
        uiPresentations.stop()
        cliStreams?.stop()
        let uiCommands = uiCommands; self.uiCommands = nil
        uiCommands?.shutdown()
        let navigation = navigation; self.navigation = nil
        navigation?.invalidate()
        draining = true
        controller?.beginShutdown()
        let pendingAlerts = Array(alertTasks.values)
        for task in pendingAlerts { task.cancel() }
        alertsTask?.cancel()
        backupRestoreTask?.cancel()
        backup?.beginSuspension()
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
        await projection?.beginSuspension()
        await reports?.beginSuspension()
        await statusLine?.beginSuspension()
        await uiPresentations.stopAndWait()
        await backup?.shutdown()
        await backupRestoreTask?.value
        await navigation?.stopAndWait()
        await uiCommands?.shutdownAndWait()
        await cliStreams?.stopAndWait()
        await connectionTask?.value
        try? cliHooks?.shutdown()
        try? await statusLine?.shutdown()
        await controller?.shutdown()
        await task?.value
        for task in pendingAlerts { await task.value }
        await alerts?.shutdown()
        await reports?.shutdown()
        await projection?.shutdown()
        if UsageExecutionEnvironment.fixtureHome == nil {
            await UsageLimitAlerts.removePending()
            LimitNotifier.shared.shutdown()
        }
    }

    func prepareUIToClose(_ presentation: UUID) async -> String? {
        guard let scene = uiPresentations.scenes[presentation] else {
            return "Usage presentation is unavailable."
        }
        await scene.shutdownAndWait()
        return nil
    }

    func configureUI(_ configuration: ExtensionUIConfiguration) -> Bool {
        let input = configuration.input
        uiPresentations.prune()
        guard !draining, controller == nil, !recovering,
            configuration.extensionID == "usage",
            let text = input["presentationID"] as? String, let id = UUID(uuidString: text),
            let route = UsageUISceneRoute(context: input),
            !configuration.uiOnly || route.location == .settings
        else { return false }
        if let existing = uiPresentations.scenes[id] {
            return existing.matches(input)
        }
        let scene = UsageUIPresentation(
            id: id, route: route,
            client: configuration.engineClient.map { UsageUIClient(client: $0) },
            readOnly: configuration.uiOnly)
        if !uiPresentations.configure(scene) {
            scene.shutdown(); return false
        }
        return true
    }

    func start(_ context: ExtensionHostContext) -> Bool {
        let input = context.input
        guard !draining, !ExtensionHostRole.isInterfaceProcess, uiPresentations.isEmpty
        else {
            return false
        }
        guard let suite = input["defaultsSuite"] as? String,
            suite == ExtensionEnvironment.values["EDITH_SHARED_DEFAULTS_SUITE"]
        else { return false }
        let fixture: Bool
        do { fixture = try admitFixture(input) != nil } catch {
            return false
        }
        guard controller == nil, !recovering else { return true }
        let launcher = ClaudeStatusLine.publicExecutable(fromVerifiedContext: input)
        let statusLine = UsageStatusLineCommands(executable: launcher)
        self.statusLine = statusLine
        let cliHooks = UsageCLIHookOwner(executable: launcher)
        self.cliHooks = cliHooks
        if input["recoveryOnly"] as? Bool == true {
            recovering = true
            return true
        }
        if !fixture {
            do { backup = try UsageBackupProvider.live() } catch {
                return false
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
            return false
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
            try? await statusLine.ensureConnected()
            try? cliHooks.resumeOwnedHooks()
        }
        if !fixture {
            let alerts = UsageLimitAlerts(); self.alerts = alerts
            _ = LimitNotifier.shared
            observers.append(
                UsageEvents.observe(UsageEvents.limitsUpdated) { [weak self] in
                    guard let self, !self.draining, let snapshot = self.controller?.latestLimits
                    else { return }
                    self.alertsTask?.cancel()
                    let id = UUID()
                    let task = Task { [self] in
                        defer { self.alertTasks[id] = nil }
                        try? await alerts.evaluate(snapshot)
                    }
                    self.alertTasks[id] = task
                    self.alertsTask = task
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
        return true
    }

    func view(for presentation: UUID, context: ExtensionHostContext) -> NSViewController? {
        let input = context.input
        guard let text = input["presentationID"] as? String, let id = UUID(uuidString: text),
            let scene = uiPresentations.scenes[id], scene.matches(input)
        else { return nil }
        return scene.controller()
    }

    func synchronize(_ context: ExtensionHostContext) -> Bool {
        let input = context.input
        guard !draining else { return false }
        do {
            _ = try admitFixture(input)
            guard let controller else { return false }
            try controller.synchronizeAmbientPolicy(context: input) {
                usageStore?.syncStatusItem(); usageStore?.refreshMenuBarItem()
                backup?.preferencesChanged()
            }
        } catch {
            return false
        }
        return true
    }

    func stopUI() -> [Task<Void, Never>] {
        uiPresentations.stop()
        return uiPresentations.scenes.values.map { scene in
            Task { await scene.shutdownAndWait() }
        }
    }

    func perform(_ operation: String, context: NSDictionary) -> NSObject? {
        guard operation == "releaseUI",
            let text = context["presentationID"] as? String, let id = UUID(uuidString: text)
        else { return nil }
        uiPresentations.release(id)
        return ["ok": true] as NSDictionary
    }

}

@MainActor
func makeUsageRuntime(
    admitFixture: ((NSDictionary) throws -> WorkerFixtureAdmission?)? = nil
) -> ExtensionServiceRuntime {
    final class BundleAnchor {}
    return ExtensionServiceRuntime(id: "usage", role: "app", bundle: Bundle(for: BundleAnchor.self))
    {
        _ in
        return UsageService(admitFixture: admitFixture)
    }
}

@_cdecl("edith_extension_create")
public func createExtension() -> UnsafeMutableRawPointer? {
    UnsafeMutableRawPointer(
        bitPattern: MainActor.assumeIsolated {
            UInt(bitPattern: Unmanaged.passRetained(makeUsageRuntime()).toOpaque())
        })
}
