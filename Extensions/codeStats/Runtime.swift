import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import SwiftUI

@MainActor @objc(EdithCodeStatsExtensionRuntime)
final class ExtensionRuntime: NSObject {
    private var workflow: CodeStatsWorkflow?
    private var surface: CodeStatsSurface?
    private var operations: CodeStatsCommands?
    private var startup: Task<Void, Never>?
    private var schedule: Task<Void, Never>?
    private var wake: Task<Void, Never>?
    private var volumeWatch: CodeStatsVolumeWatch?
    private var defaultsObserver: NSObjectProtocol?
    private let commands = ExtensionCommandRegistry()

    @objc func invoke(_ request: NSDictionary, completion: @escaping (NSData?, NSString?) -> Void) {
        commands.invoke(request, completion: completion) { [weak self] command, payload in
            guard let self, self.workflow != nil else { throw ExtensionPeerError.unavailable }
            await self.startup?.value
            try Task.checkCancellation()
            if command.hasPrefix("surface."), let surface = self.surface {
                return try await surface.execute(command, payload: payload)
            }
            guard let operations = self.operations else { throw ExtensionPeerError.unavailable }
            return try await operations.execute(command, payload: payload)
        }
    }

    @objc(prepareToStopWithCompletion:)
    func prepareToStop(completion: @escaping () -> Void) {
        commands.shutdown()
        schedule?.cancel(); wake?.cancel(); startup?.cancel()
        volumeWatch?.stop(); volumeWatch = nil
        if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) }
        defaultsObserver = nil
        CodeStatsModel.shared.cancelLoading()
        CodeStatsWorkerOperations.workflow = nil
        let workflow = workflow; self.workflow = nil
        let operations = operations; self.operations = nil
        let jobs = [startup, schedule, wake]; startup = nil; schedule = nil; wake = nil
        surface = nil
        Task {
            await workflow?.shutdown()
            await operations?.shutdown()
            for job in jobs { await job?.value }
            completion()
        }
    }

    @objc func execute(_ input: NSDictionary) -> NSObject {
        switch input["operation"] as? String {
        case "describe":
            let bundle = Bundle(for: ExtensionRuntime.self)
            return [
                "id": "codeStats", "role": "app",
                "version": bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                    as? String ?? "",
                "hostABI": bundle.object(forInfoDictionaryKey: "EdithHostABI") as? String ?? "",
            ] as NSDictionary
        case "start":
            guard let suite = input["defaultsSuite"] as? String,
                suite == ProcessInfo.processInfo.environment["EDITH_SHARED_DEFAULTS_SUITE"]
            else { return ["ok": false] as NSDictionary }
            guard workflow == nil else { return ["ok": true] as NSDictionary }
            CodeStatsPaths.prepare()
            let store = CodeStatsStore()
            let workflow = CodeStatsWorkflow(environment: .live)
            self.workflow = workflow; CodeStatsWorkerOperations.workflow = workflow
            surface = CodeStatsSurface(store: store, workflow: workflow)
            operations = CodeStatsCommands(workflow: workflow, store: store)
            startup = Task {
                await workflow.recoverInterruptedRun()
                if CodeStatsExecutionEnvironment.fixtureHome != nil, !Task.isCancelled {
                    await CodeStatsModel.shared.loadReport()
                }
            }
            if CodeStatsExecutionEnvironment.fixtureHome == nil {
                let watcher = CodeStatsVolumeWatch(); volumeWatch = watcher
                watcher.start { [weak self] in Task { @MainActor in self?.wakeSchedule() } }
                defaultsObserver = NotificationCenter.default.addObserver(
                    forName: UserDefaults.didChangeNotification,
                    object: SharedDefaults.store, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.wakeSchedule() }
                }
                schedule = Task { [weak self] in
                    await self?.startup?.value
                    while !Task.isCancelled {
                        _ = await workflow.scheduledCheck()
                        do { try await Task.sleep(for: .seconds(30)) } catch { return }
                    }
                }
            }
        case "view":
            guard workflow != nil else { return ["ok": false] as NSDictionary }
            return NSHostingController(
                rootView: ExtensionPageHost {
                    CodeStatsWorkerPage().environment(
                        \.automaticViewActionsEnabled,
                        CodeStatsExecutionEnvironment.fixtureHome == nil)
                })
        case "cancelCommand": commands.cancel(input["token"] as? String ?? "")
        case "synchronize": wakeSchedule()
        case "stop": prepareToStop(completion: {})
        case "status": return ["ok": true, "running": workflow != nil] as NSDictionary
        default: return ["ok": false] as NSDictionary
        }
        return ["ok": true] as NSDictionary
    }

    private func wakeSchedule() {
        guard CodeStatsExecutionEnvironment.fixtureHome == nil, let workflow else { return }
        wake?.cancel()
        wake = Task { [weak self] in
            await self?.startup?.value
            guard !Task.isCancelled else { return }
            await workflow.settingsChanged()
            guard !Task.isCancelled else { return }
            _ = await workflow.scheduledCheck()
        }
    }
}

private struct CodeStatsWorkerPage: View {
    @State private var settings = false
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Statistics") { settings = false }
                Button("Settings") { settings = true }
                Spacer()
            }.padding(UIScale.pt(12))
            if settings {
                Form { CodeStatsRows() }.formStyle(.grouped)
            } else {
                CodeStatsPage(model: CodeStatsModel.shared)
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
