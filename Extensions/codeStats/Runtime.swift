import AppKit
#if SWIFT_PACKAGE
import WorkerFixtureSupport
#endif
import EdithExtensionSupport
import EdithExtensionCommands
import EdithExtensionUI
import Foundation
import SwiftUI

@MainActor @objc(EdithCodeStatsExtensionRuntime)
final class ExtensionRuntime: NSObject {
    private let fixtureAdmission: (NSDictionary) throws -> WorkerFixtureAdmission?
    private let settingsWake: (@MainActor () -> Void)?
    private var fixtureMode = false
    private var workflow: CodeStatsWorkflow?
    private var uiModel: CodeStatsModel?
    private var engineClient: ExtensionEngineClient?
    private var surface: CodeStatsSurface?
    private var operations: CodeStatsCommands?
    private var startup: Task<Void, Never>?
    private let ambientPolicy = ExtensionAmbientPolicy(jobs: [
        CodeStatsScheduleLifecycle.jobID: .init(ambient: 600)
    ])
    private var schedule: CodeStatsScheduleLifecycle?
    private var wake: Task<Void, Never>?
    private var volumeWatch: CodeStatsVolumeWatch?
    private var defaultsObserver: NSObjectProtocol?
    private let commands = ExtensionCommandRegistry()
    private var cliStreams: ExtensionCLIStreams?

    init(
        settingsWake: (@MainActor () -> Void)? = nil,
        fixtureAdmission: @escaping (NSDictionary) throws -> WorkerFixtureAdmission? = {
            try WorkerFixtureAdmission.current(
                extensionID: "codeStats", context: $0,
                roleBundle: Bundle(for: ExtensionRuntime.self))
        }
    ) {
        self.fixtureAdmission = fixtureAdmission
        self.settingsWake = settingsWake
        super.init()
    }

    @objc func invoke(_ request: NSDictionary, completion: @escaping (NSData?, NSString?) -> Void) {
        commands.invoke(request, completion: completion) { [weak self] command, payload in
            guard let self, self.workflow != nil else { throw ExtensionPeerError.unavailable }
            await self.startup?.value
            try Task.checkCancellation()
            if command.hasPrefix("codeStats.cli.") {
                if self.cliStreams == nil {
                    self.cliStreams = try ExtensionCLIStreams(owner: "codeStats")
                }
                guard let streams = self.cliStreams else { throw ExtensionPeerError.unavailable }
                return try streams.invoke(
                    CodeStatsCLICommand.self, operation: command, prefix: "codeStats.cli",
                    payload: payload)
            }
            if command == "codeStats.cli" {
                let request = try JSONDecoder().decode(ExtensionCLIRequest.self, from: payload)
                return try JSONEncoder().encode(try await CodeStatsCLIExecution.run(request))
            }
            if command.hasPrefix("codeStats.ui."), let workflow = self.workflow {
                return try await CodeStatsUIBridge.execute(
                    command, payload: payload, workflow: workflow)
            }
            if command.hasPrefix("surface."), let surface = self.surface {
                return try await surface.execute(command, payload: payload)
            }
            guard let operations = self.operations else { throw ExtensionPeerError.unavailable }
            return try await operations.execute(command, payload: payload)
        }
    }

    @objc(prepareToStopWithCompletion:)
    func prepareToStop(completion: @escaping () -> Void) {
        let streams = cliStreams; cliStreams = nil; streams?.stop()
        commands.shutdown()
        ambientPolicy.stop()
        schedule?.cancel(); wake?.cancel(); startup?.cancel()
        volumeWatch?.stop(); volumeWatch = nil
        if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) }
        defaultsObserver = nil
        CodeStatsModel.shared.cancelLoading()
        CodeStatsWorkerOperations.workflow = nil
        let workflow = workflow; self.workflow = nil
        let operations = operations; self.operations = nil
        let schedule = schedule; self.schedule = nil
        let jobs = [startup, wake]; startup = nil; wake = nil
        surface = nil
        Task {
            await schedule?.shutdown()
            await workflow?.shutdown()
            await operations?.shutdown()
            for job in jobs { await job?.value }
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
                "id": "codeStats", "role": "app",
                "version": bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                    as? String ?? "",
                "hostABI": bundle.object(forInfoDictionaryKey: "EdithHostABI") as? String ?? "",
            ] as NSDictionary
        case "configureUI":
            guard engineClient == nil, let configuration = ExtensionUIConfiguration(context: input),
                configuration.extensionID == "codeStats", let client = configuration.engineClient
            else { return ["ok": false] as NSDictionary }
            engineClient = client
            let bridge = CodeStatsUIBridge(client: client)
            uiModel = CodeStatsModel(service: bridge.service, remote: bridge)
        case "stopUI":
            uiModel?.cancelLoading(); uiModel = nil
            engineClient?.invalidate(); engineClient = nil
        case "start":
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
            guard workflow == nil else { return ["ok": true] as NSDictionary }
            fixtureMode = fixture
            if !fixture {
                do { try ambientPolicy.start { [weak self] in self?.schedule?.reschedule() } } catch
                { return ["ok": false] as NSDictionary }
            }
            CodeStatsPaths.prepare()
            let store = CodeStatsStore()
            let workflow = CodeStatsWorkflow(environment: .live)
            self.workflow = workflow; CodeStatsWorkerOperations.workflow = workflow
            surface = CodeStatsSurface(store: store, workflow: workflow)
            operations = CodeStatsCommands(workflow: workflow, store: store)
            startup = Task {
                await workflow.recoverInterruptedRun()
                if fixture, !Task.isCancelled {
                    await CodeStatsModel.shared.loadReport()
                }
            }
            if !fixture {
                let watcher = CodeStatsVolumeWatch(); volumeWatch = watcher
                watcher.start { [weak self] in Task { @MainActor in self?.wakeSchedule() } }
                defaultsObserver = NotificationCenter.default.addObserver(
                    forName: UserDefaults.didChangeNotification,
                    object: SharedDefaults.store, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.wakeSchedule() }
                }
                let policy = ambientPolicy
                let schedule = CodeStatsScheduleLifecycle(
                    interval: { policy.interval(for: CodeStatsScheduleLifecycle.jobID) },
                    ready: { [weak self] in await self?.startup?.value },
                    check: { _ = await workflow.scheduledCheck() })
                self.schedule = schedule
                schedule.start()
            }
        case "view":
            guard let model = uiModel else { return ["ok": false] as NSDictionary }
            let settings = input["location"] as? String == "settings"
            return NSHostingController(
                rootView: ExtensionPageHost {
                    if settings {
                        Form { CodeStatsRows(model: model) }.formStyle(.grouped)
                    } else {
                        CodeStatsPage(model: model)
                    }
                })
        case "cancelCommand": commands.cancel(input["token"] as? String ?? "")
        case "synchronize":
            do { _ = try fixtureAdmission(input) } catch { return ["ok": false] as NSDictionary }
            do { try ambientPolicy.apply(context: input) } catch {
                return ["ok": false] as NSDictionary
            }
            if input["ambientPolicyOnly"] as? Bool != true {
                if let settingsWake { settingsWake() } else { wakeSchedule() }
            }
        case "stop": prepareToStop(completion: {})
        case "status": return ["ok": true, "running": workflow != nil] as NSDictionary
        default: return ["ok": false] as NSDictionary
        }
        return ["ok": true] as NSDictionary
    }

    private func wakeSchedule() {
        guard !fixtureMode, let workflow else { return }
        wake?.cancel()
        wake = Task { [weak self] in
            await self?.startup?.value
            guard !Task.isCancelled else { return }
            await workflow.settingsChanged()
            guard !Task.isCancelled else { return }
            if let schedule = self?.schedule {
                await schedule.runExplicit()
            } else {
                _ = await workflow.scheduledCheck()
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
