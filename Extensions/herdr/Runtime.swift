import Darwin
import AppKit
import EdithExtensionCommands
import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI
#if SWIFT_PACKAGE
import WorkerFixtureSupport
#endif

@MainActor
final class HerdrService: ExtensionService {
    private struct UIPresentation {
        let location: String
        let client: ExtensionEngineClient?
        var store: HerdrStore?
        var activity: AgentActivityMonitor?
        var sessionSettings: HerdrSessionSettingsModel?
        var settings: HerdrSettingsModel?
        var controller: NSViewController?
    }
    private var presentations: [UUID: UIPresentation] = [:]
    private var worker: HerdrWorker?
    private var surface: HerdrSurface?
    private var startup: Task<Void, Never>?
    private var draining = false
    private var drainTask: Task<Void, Never>?
    private var uiRetirements: [UUID: Task<Void, Never>] = [:]
    private let fixtureAdmission: @MainActor (NSDictionary) throws -> WorkerFixtureAdmission?
    private let workerFactory: @MainActor (NSDictionary, WorkerFixtureAdmission?) -> HerdrWorker
    private var fixture: WorkerFixtureAdmission?

    init(
        fixtureAdmission: (@MainActor (NSDictionary) throws -> WorkerFixtureAdmission?)? = nil,
        workerFactory: (@MainActor (NSDictionary, WorkerFixtureAdmission?) -> HerdrWorker)? = nil
    ) {
        self.fixtureAdmission =
            fixtureAdmission ?? { context in
                try WorkerFixtureAdmission.current(
                    extensionID: "herdr", context: context,
                    roleBundle: Bundle(for: HerdrService.self))
            }
        self.workerFactory = workerFactory ?? Self.makeWorker
    }

    private static func makeWorker(
        _ input: NSDictionary, fixture: WorkerFixtureAdmission?
    ) -> HerdrWorker {
        let navigation = (input["hostNavigation"] as? NSObject).flatMap {
            HerdrHostWindowNavigationClient(bridge: $0)
        }
        let folderChoice = (input["hostNavigation"] as? NSObject).flatMap {
            HerdrHostFolderChoiceClient(bridge: $0)
        }
        return HerdrWorker(
            hostWindowNavigation: navigation, hostFolderChoice: folderChoice, fixture: fixture)
    }

    private func matchesFixture(_ next: WorkerFixtureAdmission?) -> Bool {
        next?.extensionID == fixture?.extensionID && next?.role == fixture?.role
            && next?.home == fixture?.home && next?.dataDirectory == fixture?.dataDirectory
    }

    func invoke(_ command: String, payload: Data) async throws -> Data {
        guard let worker = self.worker else { throw ExtensionPeerError.unavailable }
        await self.startup?.value
        if command == "herdr.cli" {
            let request = try JSONDecoder().decode(ExtensionCLIRequest.self, from: payload)
            return try JSONEncoder().encode(
                await HerdrCLIExecution.run(request, worker: worker))
        }
        if command.hasPrefix("surface.") {
            guard let surface = self.surface else { throw ExtensionPeerError.unavailable }
            return try await surface.execute(command, payload: payload)
        }
        return try await worker.execute(command, payload: payload)
    }

    var preparesForDisable: Bool { true }
    var allowsUIDuringRetirement: Bool { true }
    var isRunning: Bool { worker?.isStopped == false }

    func cancelPendingWork() {
        guard drainTask == nil else { return }
        draining = true
        let current = Array(presentations.values)
        for presentation in current {
            presentation.store?.cancelPendingWork()
            presentation.activity?.beginCommandDrain()
            presentation.sessionSettings?.shutdown()
            presentation.settings?.shutdown()
        }
        startup?.cancel()
        worker?.requestWorkCancellation()
        let startup = startup, worker = worker
        let retired = Array(uiRetirements.values)
        drainTask = Task {
            await startup?.value
            await worker?.cancelPendingWork()
            for presentation in current {
                await presentation.store?.drain()
                await presentation.sessionSettings?.stopAndWait()
                await presentation.settings?.stopAndWait()
                await presentation.activity?.cancelPendingWorkAndWait()
            }
            for task in retired { await task.value }
        }
    }

    func drain() async { await drainTask?.value }

    func prepareDisable() async throws {
        try await worker?.prepareDisable()
    }

    func teardown() async {
        await worker?.shutdown()
        stopAllUI()
        for task in Array(uiRetirements.values) { await task.value }
        worker = nil
        fixture = nil
        surface = nil
        startup = nil
    }

    func configureUI(_ configuration: ExtensionUIConfiguration) -> Bool {
        let input = configuration.input
        guard worker == nil, let location = input["location"] as? String,
            [
                "main", "settings", "notch", "herdr.agent", "herdr.agent.controls",
                "herdr.space", "herdr.files",
            ]
            .contains(location),
            let origin = input["presentationID"] as? String,
            let presentationID = UUID(uuidString: origin),
            configuration.extensionID == "herdr",
            location == "settings" || configuration.engineClient != nil
        else { return false }
        let settingsSection = (input["section"] as? String).flatMap(HerdrSettingsSection.init)
        guard location != "settings" || settingsSection != nil else {
            return false
        }
        if location.hasPrefix("herdr.") {
            guard let target = input["target"] as? String, !target.isEmpty,
                target.utf8.count <= (location == "herdr.files" ? 8192 : 4096),
                !target.utf8.contains(0),
                let raw = input["herdrPresentationToken"] as? String,
                UUID(uuidString: raw) != nil
            else { return false }
        }
        stopUI(presentationID)
        var presentation = UIPresentation(
            location: location, client: configuration.engineClient)
        if location != "settings", let client = configuration.engineClient {
            let facade = HerdrUIClient(client: client)
            let store = HerdrStore(uiClient: facade)
            store.uiPresentationID = presentationID
            store.terminalUI = store.makeTerminalUIPresentation(
                id: presentationID,
                location: location, target: input["target"] as? String ?? "",
                token: (input["herdrPresentationToken"] as? String).flatMap(
                    UUID.init(uuidString:)))
            let activity = AgentActivityMonitor(defaults: store.uiDefaults, uiClient: facade)
            store.uiActivity = activity
            presentation.store = store
            presentation.activity = activity
            presentation.controller = NSHostingController(
                rootView: ExtensionPageHost {
                    if location == "main" {
                        HerdrPage(store: store, activity: activity)
                            .environment(\.terminalLaunchEnabled, true)
                    } else if location == "notch" {
                        HerdrNotchAgentsCard(store: store, monitor: activity)
                    } else {
                        HerdrRemoteScene(
                            store: store, location: location,
                            target: input["target"] as? String ?? "",
                            token: UUID(
                                uuidString: input["herdrPresentationToken"] as? String ?? "")!
                        )
                        .environment(\.terminalLaunchEnabled, true)
                    }
                })
            PresenterState.shared.acquire(presentationID)
        } else if settingsSection == .agentActivity {
            let facade: HerdrUIClient
            if let client = configuration.engineClient {
                facade = HerdrUIClient(client: client)
            } else {
                facade = HerdrUIClient { _, _ in throw ExtensionPeerError.unavailable }
            }
            let store = HerdrStore(uiClient: facade)
            store.uiPresentationID = presentationID
            let activity = AgentActivityMonitor(defaults: store.uiDefaults, uiClient: facade)
            activity.folderPresentationID = presentationID
            store.uiActivity = activity
            presentation.store = store
            presentation.activity = activity
            presentation.controller = NSHostingController(
                rootView: ExtensionPageHost {
                    HerdrActivitySettingsPage(store: store, monitor: activity)
                })
        } else if settingsSection == .extensionSettings {
            let facade: HerdrUIClient
            if let client = configuration.engineClient {
                facade = HerdrUIClient(client: client)
            } else {
                facade = HerdrUIClient { _, _ in throw ExtensionPeerError.unavailable }
            }
            let model = HerdrSessionSettingsModel(client: facade)
            presentation.sessionSettings = model
            presentation.controller = NSHostingController(
                rootView: ExtensionPageHost { HerdrExtensionSettingsPage(model: model) })
        } else {
            let model: HerdrSettingsModel
            if let client = configuration.engineClient {
                model = HerdrSettingsModel(client: client)
            } else {
                model = HerdrSettingsModel { _, _ in throw ExtensionPeerError.unavailable }
            }
            presentation.settings = model
            presentation.controller = NSHostingController(
                rootView: ExtensionPageHost { HerdrSettingsPage(model: model) })
        }
        presentations[presentationID] = presentation
        return true
    }

    func start(_ context: ExtensionHostContext) -> Bool {
        let input = context.input
        guard presentations.isEmpty, !ExtensionHostRole.isInterfaceProcess else {
            return false
        }
        let admitted: WorkerFixtureAdmission?
        do { admitted = try fixtureAdmission(input) } catch {
            return false
        }
        if admitted == nil {
            guard let suite = input["defaultsSuite"] as? String,
                suite == ExtensionEnvironment.values["EDITH_SHARED_DEFAULTS_SUITE"]
            else { return false }
        }
        if let worker {
            guard matchesFixture(admitted) else { return false }
            do { try worker.applyAmbientPolicy(context: input) } catch {
                return false
            }
            return true
        }
        let created = workerFactory(input, admitted)
        do { try created.applyAmbientPolicy(context: input) } catch {
            return false
        }
        fixture = admitted
        worker = created
        surface = HerdrSurface(worker: created)
        let recovery =
            input["recoveryOnly"] as? Bool == true
            || ExtensionEnvironment.values["EDITH_EXTENSION_RECOVERY_ONLY"] == "1"
        if !recovery { startup = Task { await created.start() } }
        return true
    }

    func view(for identifier: UUID, context: ExtensionHostContext) -> NSViewController? {
        let input = context.input
        guard let presentation = presentation(input),
            input["location"] as? String == presentation.location,
            let controller = presentation.controller
        else { return nil }
        return controller
    }

    func synchronize(_ context: ExtensionHostContext) -> Bool {
        let input = context.input
        guard !draining, let worker else { return false }
        do {
            guard matchesFixture(try fixtureAdmission(input)) else {
                return false
            }
            try worker.applyAmbientPolicy(context: input)
        } catch { return false }
        return true
    }

    func stopUI(for presentation: UUID?) -> [Task<Void, Never>] {
        if let presentation { stopUI(presentation) } else { stopAllUI() }
        return Array(uiRetirements.values)
    }

    func perform(_ operation: String, context: NSDictionary) -> NSObject? {
        guard ["terminalUI", "terminalUIStatus"].contains(operation),
            let binding = presentation(context)?.store?.terminalUI
        else { return nil }
        let input = context.mutableCopy() as! NSMutableDictionary
        input["operation"] = operation
        return binding.execute(input)
    }

    private func presentationID(_ input: NSDictionary) -> UUID? {
        (input["presentationID"] as? String).flatMap(UUID.init(uuidString:))
    }

    private func presentation(_ input: NSDictionary) -> UIPresentation? {
        presentationID(input).flatMap { presentations[$0] }
    }

    private func stopAllUI() {
        for id in Array(presentations.keys) { stopUI(id) }
    }

    private func stopUI(_ id: UUID) {
        guard let presentation = presentations.removeValue(forKey: id) else { return }
        PresenterState.shared.release(id)
        presentation.sessionSettings?.shutdown()
        presentation.settings?.shutdown()
        presentation.store?.stopRendering()
        presentation.activity?.beginCommandDrain()
        presentation.client?.invalidate()
        let retirement = UUID()
        uiRetirements[retirement] = Task { [self, presentation] in
            await presentation.store?.shutdown()
            await presentation.activity?.shutdown()
            await presentation.sessionSettings?.stopAndWait()
            await presentation.settings?.stopAndWait()
            uiRetirements[retirement] = nil
        }
    }

}

@MainActor
func makeHerdrRuntime(
    fixtureAdmission: (@MainActor (NSDictionary) throws -> WorkerFixtureAdmission?)? = nil,
    workerFactory: (@MainActor (NSDictionary, WorkerFixtureAdmission?) -> HerdrWorker)? = nil
) -> ExtensionServiceRuntime {
    final class BundleAnchor {}
    return ExtensionServiceRuntime(id: "herdr", role: "app", bundle: Bundle(for: BundleAnchor.self))
    {
        _ in
        return HerdrService(fixtureAdmission: fixtureAdmission, workerFactory: workerFactory)
    }
}

@_cdecl("edith_extension_create")
public func createExtension() -> UnsafeMutableRawPointer? {
    let address = MainActor.assumeIsolated {
        UInt(bitPattern: Unmanaged.passRetained(makeHerdrRuntime()).toOpaque())
    }
    return UnsafeMutableRawPointer(bitPattern: address)
}

@_cdecl("edith_extension_native_task")
public func runNativeTask(_ bytes: UnsafePointer<UInt8>?, _ count: Int32) -> Int32 {
    guard let bytes, count > 0, count <= 65_536 else { return 1 }
    do {
        if let root = ExtensionEnvironment.values["EDITH_EXTENSION_FIXTURE_HOME"] {
            let receipt = try JSONSerialization.data(withJSONObject: [
                "pid": getpid(), "parent": getppid(), "group": getpgrp(),
                "owner": Int32(
                    ExtensionEnvironment.values["EDITH_EXTENSION_NATIVE_PARENT"] ?? "")
                    ?? 0,
                "inputTerminal": isatty(STDIN_FILENO), "bytes": count,
            ])
            try receipt.write(
                to: URL(fileURLWithPath: root).appendingPathComponent("herdr-native-receipt.json"))
        }
        try HerdrBridgeCommand.run(
            encoded: Data(bytes: bytes, count: Int(count)).base64EncodedString())
        return 0
    } catch let error as HerdrBridgeExit { return error.status } catch {
        FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
        return 1
    }
}
