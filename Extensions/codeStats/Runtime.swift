import AppKit
#if SWIFT_PACKAGE
import WorkerFixtureSupport
#endif
import EdithExtensionSupport
import EdithExtensionCommands
import EdithExtensionUI
import Foundation
import SwiftUI

private final class CodeStatsBundleAnchor {}

@MainActor
final class CodeStatsService: ExtensionService {
    private let fixtureAdmission: (NSDictionary) throws -> WorkerFixtureAdmission?
    private let settingsWake: (@MainActor () -> Void)?
    private var fixtureMode = false
    private var workflow: CodeStatsWorkflow?
    private var uiModel: CodeStatsModel?
    private var uiSettings = false
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
    private var cliStreams: ExtensionCLIStreams?

    init(
        settingsWake: (@MainActor () -> Void)? = nil,
        fixtureAdmission: @escaping (NSDictionary) throws -> WorkerFixtureAdmission? = {
            try WorkerFixtureAdmission.current(
                extensionID: "codeStats", context: $0,
                roleBundle: Bundle(for: CodeStatsBundleAnchor.self))
        }
    ) {
        self.fixtureAdmission = fixtureAdmission
        self.settingsWake = settingsWake
    }

    var isRunning: Bool { workflow != nil }
    var allowsUIDuringRetirement: Bool { true }

    func start(_ context: ExtensionHostContext) -> Bool {
        let input = context.input
        let fixture: Bool
        do { fixture = try fixtureAdmission(input) != nil } catch { return false }
        do { try ambientPolicy.apply(context: input) } catch { return false }
        guard workflow == nil else { return true }
        fixtureMode = fixture
        if !fixture {
            do { try ambientPolicy.start { [weak self] in self?.schedule?.reschedule() } } catch {
                return false
            }
        }
        CodeStatsPaths.prepare()
        let store = CodeStatsStore()
        let workflow = CodeStatsWorkflow(environment: .live)
        self.workflow = workflow
        CodeStatsWorkerOperations.workflow = workflow
        surface = CodeStatsSurface(store: store, workflow: workflow)
        operations = CodeStatsCommands(workflow: workflow, store: store)
        Task { await workflow.preload() }
        startup = Task {
            await workflow.recoverInterruptedRun()
            if fixture, !Task.isCancelled {
                await CodeStatsModel.shared.loadReport()
            }
        }
        if !fixture {
            let watcher = CodeStatsVolumeWatch()
            volumeWatch = watcher
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
        return true
    }

    func synchronize(_ context: ExtensionHostContext) -> Bool {
        let input = context.input
        do { _ = try fixtureAdmission(input) } catch { return false }
        do { try ambientPolicy.apply(context: input) } catch { return false }
        if input["ambientPolicyOnly"] as? Bool != true {
            if let settingsWake { settingsWake() } else { wakeSchedule() }
        }
        return true
    }

    func invoke(_ command: String, payload: Data) async throws -> Data {
        guard workflow != nil else { throw ExtensionPeerError.unavailable }
        await startup?.value
        try Task.checkCancellation()
        if command == "codeStats.cli.catalog" {
            return try ExtensionCLICatalog.data(
                CodeStatsCLICommand.self, owner: "codeStats", payload: payload, streaming: true)
        }
        if command.hasPrefix("codeStats.cli.") {
            if cliStreams == nil {
                cliStreams = try ExtensionCLIStreams(owner: "codeStats")
            }
            guard let streams = cliStreams else { throw ExtensionPeerError.unavailable }
            return try streams.invoke(
                CodeStatsCLICommand.self, operation: command, prefix: "codeStats.cli",
                payload: payload)
        }
        if command == "codeStats.cli" {
            let request = try JSONDecoder().decode(ExtensionCLIRequest.self, from: payload)
            return try JSONEncoder().encode(try await CodeStatsCLIExecution.run(request))
        }
        if command.hasPrefix("codeStats.ui."), let workflow {
            return try await CodeStatsUIBridge.execute(
                command, payload: payload, workflow: workflow)
        }
        if command.hasPrefix("surface."), let surface {
            return try await surface.execute(command, payload: payload)
        }
        guard let operations else { throw ExtensionPeerError.unavailable }
        return try await operations.execute(command, payload: payload)
    }

    func configureUI(_ configuration: ExtensionUIConfiguration) -> Bool {
        guard engineClient == nil, let client = configuration.engineClient else { return false }
        engineClient = client
        uiSettings = configuration.isSettings
        let bridge = CodeStatsUIBridge(client: client)
        uiModel = CodeStatsModel(service: bridge.service, remote: bridge)
        return true
    }

    func view(for presentation: UUID) -> NSViewController? {
        guard let model = uiModel else { return nil }
        let settings = uiSettings
        return NSHostingController(
            rootView: ExtensionPageHost {
                if settings {
                    Form { CodeStatsRows(model: model) }.edithForm()
                } else {
                    CodeStatsPage(model: model)
                }
            })
    }

    func stopUI() -> [Task<Void, Never>] {
        releaseUI()
        return []
    }

    func cancelPendingWork() {
        cliStreams?.stop()
    }

    func drain() async {
        await cliStreams?.stopAndWait()
    }

    func teardown() async {
        releaseUI()
        let streams = cliStreams
        cliStreams = nil
        streams?.stop()
        ambientPolicy.stop()
        schedule?.cancel()
        wake?.cancel()
        startup?.cancel()
        volumeWatch?.stop()
        volumeWatch = nil
        if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) }
        defaultsObserver = nil
        CodeStatsModel.shared.cancelLoading()
        CodeStatsWorkerOperations.workflow = nil
        let workflow = workflow
        self.workflow = nil
        let operations = operations
        self.operations = nil
        let schedule = schedule
        self.schedule = nil
        let jobs = [startup, wake]
        startup = nil
        wake = nil
        surface = nil
        await schedule?.shutdown()
        await workflow?.shutdown()
        await operations?.shutdown()
        for job in jobs { await job?.value }
        await streams?.stopAndWait()
    }

    private func releaseUI() {
        uiModel?.cancelLoading()
        uiModel = nil
        uiSettings = false
        engineClient?.invalidate()
        engineClient = nil
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

@MainActor
func makeCodeStatsRuntime(
    settingsWake: (@MainActor () -> Void)? = nil,
    fixtureAdmission: ((NSDictionary) throws -> WorkerFixtureAdmission?)? = nil
) -> ExtensionServiceRuntime {
    ExtensionServiceRuntime(
        id: "codeStats", role: "app", bundle: Bundle(for: CodeStatsBundleAnchor.self)
    ) { _ in
        if let fixtureAdmission {
            return CodeStatsService(settingsWake: settingsWake, fixtureAdmission: fixtureAdmission)
        }
        return CodeStatsService(settingsWake: settingsWake)
    }
}

@_cdecl("edith_extension_create")
public func createExtension() -> UnsafeMutableRawPointer? {
    UnsafeMutableRawPointer(
        bitPattern: MainActor.assumeIsolated {
            UInt(bitPattern: Unmanaged.passRetained(makeCodeStatsRuntime()).toOpaque())
        })
}
