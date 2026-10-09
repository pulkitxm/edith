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
    private var reports: UsageReportCommands?
    private var alerts: UsageLimitAlerts?
    private var alertsTask: Task<Void, Never>?
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
            guard let reports = self.reports else { throw ExtensionPeerError.unavailable }
            return try await reports.execute(command, payload: payload)
        }
    }

    @objc(prepareToStopWithCompletion:)
    func prepareToStop(completion: @escaping () -> Void) {
        commands.shutdown()
        controller?.beginShutdown()
        alertsTask?.cancel()
        for observer in observers { UsageEvents.stopObserving(observer) }
        observers = []
        usageStore?.shutdown()
        DashboardModel.shared.shutdown()
        UsagePresenterState.shared.shutdown()
        UsageWorkerOperations.controller = nil
        let controller = controller; self.controller = nil
        let alerts = alerts; self.alerts = nil
        let task = alertsTask; alertsTask = nil
        let reports = reports; self.reports = nil
        surface = nil; statusLine = nil; usageStore = nil
        Task {
            await controller?.shutdown()
            await task?.value
            await alerts?.shutdown()
            await reports?.shutdown()
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
            guard controller == nil else { return ["ok": true] as NSDictionary }
            let fixture = UsageExecutionEnvironment.fixtureHome != nil
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
            statusLine = UsageStatusLineCommands()
            reports = UsageReportCommands(controller: controller, store: cache)
            usageStore = UsageStore(showMenuBar: !fixture)
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
                controller.startBackgroundCollection()
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
