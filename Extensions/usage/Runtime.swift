import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import SwiftUI

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

    @objc func invoke(_ request: NSDictionary, completion: @escaping (NSData?, NSString?) -> Void) {
        commands.invoke(request, completion: completion) { [weak self] command, payload in
            guard let self, self.controller != nil else { throw ExtensionPeerError.unavailable }
            if command.hasPrefix("surface."), let surface = self.surface {
                return try await surface.execute(command, payload: payload)
            }
            if command.hasPrefix("usage.statusline."), let statusLine = self.statusLine {
                return try await statusLine.execute(command, payload: payload)
            }
            if command.hasPrefix("backup."), let backup = self.backup {
                await self.backupRestoreTask?.value
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
        UsageWorkerOperations.statusLineCommands = nil
        commands.shutdown()
        statusLineConnectionTask?.cancel()
        Task {
            await commands.shutdownAndWait()
            await statusLineConnectionTask?.value
            do {
                try await statusLine?.shutdown()
                completion(nil)
            } catch { completion(error as NSError) }
        }
    }

    @objc(prepareToStopWithCompletion:)
    func prepareToStop(completion: @escaping () -> Void) {
        commands.shutdown()
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
        let connectionTask = statusLineConnectionTask; statusLineConnectionTask = nil
        let backup = self.backup; self.backup = nil
        let backupRestoreTask = self.backupRestoreTask; self.backupRestoreTask = nil
        connectionTask?.cancel()
        recovering = false
        surface = nil; usageStore = nil
        Task {
            await backup?.shutdown()
            await backupRestoreTask?.value
            await commands.shutdownAndWait()
            await connectionTask?.value
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
        case "start":
            guard let suite = input["defaultsSuite"] as? String,
                suite == ProcessInfo.processInfo.environment["EDITH_SHARED_DEFAULTS_SUITE"]
            else { return ["ok": false] as NSDictionary }
            guard controller == nil, !recovering else { return ["ok": true] as NSDictionary }
            let fixture = UsageExecutionEnvironment.fixtureHome != nil
            let statusLine = UsageStatusLineCommands()
            self.statusLine = statusLine
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
                if fixture || policy == .skip { return local }
                return try await UsageMachinesPeer.merge(
                    local: local, policy: policy, onEvent: event)
            }
            self.controller = controller
            UsageWorkerOperations.controller = controller
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
            statusLineConnectionTask = Task { try? await statusLine.resumeOwnedHook() }
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
                    _ = await backup?.restoreOnEnable()
                    guard !Task.isCancelled, self?.controller === controller else { return }
                    controller?.startBackgroundCollection()
                }
            }
        case "view":
            guard controller != nil else { return ["ok": false] as NSDictionary }
            return NSHostingController(
                rootView: ExtensionPageHost {
                    UsageWorkerPage().environment(
                        \.automaticViewActionsEnabled, UsageExecutionEnvironment.fixtureHome == nil)
                })
        case "cancelCommand": commands.cancel(input["token"] as? String ?? "")
        case "synchronize": usageStore?.syncStatusItem(); usageStore?.refreshMenuBarItem()
        case "stop": prepareToStop(completion: {})
        case "status": return ["ok": true, "running": controller != nil] as NSDictionary
        default: return ["ok": false] as NSDictionary
        }
        return ["ok": true] as NSDictionary
    }
}

private struct UsageWorkerPage: View {
    @State private var settings = false
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Dashboard") { settings = false }
                Button("Settings") { settings = true }
                Spacer()
            }.padding(UIScale.pt(12))
            if settings {
                Form { UsageSettingsRows() }.formStyle(.grouped)
            } else {
                DashboardView()
            }
        }
    }
}

@_cdecl("edith_extension_create")
public func createExtension() -> UnsafeMutableRawPointer? {
    UnsafeMutableRawPointer(
        bitPattern: MainActor.assumeIsolated {
            UInt(bitPattern: Unmanaged.passRetained(ExtensionRuntime()).toOpaque())
        })
}
