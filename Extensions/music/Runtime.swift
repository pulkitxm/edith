import AppKit
import EdithExtensionCommands
import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import SwiftUI
#if canImport(WorkerFixtureSupport)
import WorkerFixtureSupport
#endif

@MainActor @objc(EdithMusicExtensionRuntime)
final class ExtensionRuntime: NSObject {
    private var worker: MusicWorker?
    private var surface: MusicSurface?
    private var uiService: MusicUIService?
    private var navigation: MusicHostNavigationBridge?
    private let embeddedUI = MusicEmbeddedRuntime()
    private var backup: MusicBackupLifecycle?
    private let commands = ExtensionCommandRegistry()
    private var stopTask: Task<Void, Never>?
    private var inertFixture = false
    #if EDITH_FUNCTIONAL_FIXTURE
    private var engineFixture: WorkerFixtureEngineAdmission?
    private var fixturePreferences: MusicUIPreferenceEngine?
    private var admittedUI: [UUID: WorkerFixtureUIAdmission] = [:]
    private let fixtureAdmission: (NSDictionary) throws -> WorkerFixtureEngineAdmission?
    #else
    private let fixtureAdmission: (NSDictionary) throws -> WorkerFixtureAdmission?
    #endif

    override init() {
        #if EDITH_FUNCTIONAL_FIXTURE
        fixtureAdmission = { input in
            try WorkerFixtureEngineAdmission.current(
                extensionID: "music", context: input,
                roleBundle: Bundle(for: ExtensionRuntime.self))
        }
        #else
        fixtureAdmission = { input in
            try MusicWorker.resolveFixture(
                admission: {
                    try WorkerFixtureAdmission.current(
                        extensionID: "music", context: input,
                        roleBundle: Bundle(for: ExtensionRuntime.self))
                },
                applicationIdentifier: ProcessInfo.processInfo.environment[
                    "EDITH_APPLICATION_IDENTIFIER"])
        }
        #endif
        super.init()
    }

    #if EDITH_FUNCTIONAL_FIXTURE
    init(fixtureAdmission: @escaping (NSDictionary) throws -> WorkerFixtureEngineAdmission?) {
        self.fixtureAdmission = fixtureAdmission
        super.init()
    }

    #else
    init(fixtureAdmission: @escaping (NSDictionary) throws -> WorkerFixtureAdmission?) {
        self.fixtureAdmission = fixtureAdmission
        super.init()
    }
    #endif
    @objc func invoke(_ request: NSDictionary, completion: @escaping (NSData?, NSString?) -> Void) {
        #if EDITH_FUNCTIONAL_FIXTURE
        let token = (request["token"] as? String).flatMap(UUID.init(uuidString:))
        #endif
        commands.invoke(request, completion: completion) { [weak self] command, payload in
            guard let self, self.worker != nil else {
                throw ExtensionPeerError.unavailable
            }
            #if EDITH_FUNCTIONAL_FIXTURE
            if let admission = self.engineFixture {
                guard let token else { throw WorkerFixtureError.invalid }
                return try self.executeFixturePreferences(
                    command, payload: payload, token: token, admission: admission)
            }
            #endif
            guard !self.inertFixture else { throw ExtensionPeerError.unavailable }
            if command.hasPrefix("backup."), let backup = self.backup {
                return try await backup.execute(command, payload: payload)
            }
            if command == "music.cli.catalog" {
                return try ExtensionCLICatalog.data(
                    MusicCommand.self, owner: "music", payload: payload, streaming: false)
            }
            if command.hasPrefix("music.ui.") || command == "music.cli" {
                guard let service = self.uiService else { throw ExtensionPeerError.unavailable }
                return try await service.execute(command, payload: payload)
            }
            guard let surface = self.surface else { throw ExtensionPeerError.unavailable }
            return try await surface.execute(command, payload: payload)
        }
    }

    @objc(suspendCommandsWithCompletion:)
    func suspendCommands(completion: @escaping () -> Void) {
        commands.suspend()
        embeddedUI.suspendCommands()
        let ownedBackup = backup
        ownedBackup?.suspendCommands()
        Task { [self, ownedBackup] in
            await commands.suspendAndWait()
            await embeddedUI.suspendCommandsAndWait()
            await ownedBackup?.suspendCommandsAndWait()
            withExtendedLifetime(self) { completion() }
        }
    }

    @objc(prepareToStopWithCompletion:)
    func prepareToStop(completion: @escaping () -> Void) {
        let pending = beginShutdown()
        Task {
            await pending.value; completion()
        }
    }

    @objc(prepareUIToClose:completion:)
    func prepareUIToClose(_ value: NSString, completion: @escaping (NSString?) -> Void) {
        guard let id = UUID(uuidString: value as String) else {
            completion("Invalid Music presentation."); return
        }
        Task {
            let failure = await embeddedUI.prepareToClose(id)
            completion(failure.map { $0 as NSString })
        }
    }

    @objc func execute(_ input: NSDictionary) -> NSObject {
        if stopTask != nil,
            !["describe", "status", "stop", "stopUI", "releaseUI", "cancelCommand"].contains(
                input["operation"] as? String ?? "")
        {
            return ["ok": false] as NSDictionary
        }
        if inertFixture,
            !["describe", "start", "stop", "status", "cancelCommand", "synchronize"].contains(
                input["operation"] as? String ?? "")
        {
            return ["ok": false] as NSDictionary
        }
        switch input["operation"] as? String {
        case "describe":
            let bundle = Bundle(for: ExtensionRuntime.self)
            return [
                "id": "music", "role": "app",
                "version": bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                    as? String ?? "",
                "hostABI": bundle.object(forInfoDictionaryKey: "EdithHostABI") as? String ?? "",
            ] as NSDictionary
        case "start":
            #if EDITH_FUNCTIONAL_FIXTURE
            do {
                let fixture = try fixtureAdmission(input)
                if let fixture {
                    try fixture.requireCurrent()
                    guard fixture.descriptor.owner == "music", fixture.descriptor.role == "app",
                        Set(fixture.descriptor.operations) == [
                            "music.ui.settings", "music.ui.action",
                        ],
                        let host = input["hostIdentifier"] as? String,
                        host == Bundle.main.bundleIdentifier,
                        let suite = input["defaultsSuite"] as? String,
                        suite == host + ".extensions.music",
                        suite == ProcessInfo.processInfo.environment["EDITH_SHARED_DEFAULTS_SUITE"],
                        worker == nil, let defaults = UserDefaults(suiteName: suite)
                    else { throw WorkerFixtureError.invalid }
                    try fixture.requireCurrent()
                    worker = try fixture.withPlatformFixture(
                        extensionID: "music", expectedRole: .app
                    ) { namespace in
                        try MusicWorker(admission: { namespace })
                    }
                    fixturePreferences = MusicUIPreferenceEngine(defaults: defaults)
                    engineFixture = fixture
                    inertFixture = true
                    return ["ok": true] as NSDictionary
                }
            } catch { return ["ok": false, "error": error.localizedDescription] as NSDictionary }
            #else
            do {
                let fixture = try fixtureAdmission(input)
                if let fixture {
                    if worker == nil { worker = try MusicWorker(admission: { fixture }) }
                    inertFixture = true
                    return ["ok": true] as NSDictionary
                }
            } catch { return ["ok": false, "error": error.localizedDescription] as NSDictionary }
            #endif
            do {
                guard
                    try WorkerFixtureAdmission.current(
                        extensionID: "music", context: input,
                        roleBundle: Bundle(for: ExtensionRuntime.self)) == nil
                else { return ["ok": false] as NSDictionary }
            } catch { return ["ok": false] as NSDictionary }
            guard Bundle.main.bundleURL.pathExtension != "appex",
                let suite = input["defaultsSuite"] as? String,
                suite == ProcessInfo.processInfo.environment["EDITH_SHARED_DEFAULTS_SUITE"],
                SurfaceHostContext.current != nil
            else { return ["ok": false] as NSDictionary }
            if navigation == nil {
                navigation = MusicHostNavigationBridge(bridge: input["hostNavigation"] as? NSObject)
            }
            MusicHostNavigation.navigate = { [weak navigation] request in
                guard let navigation else { throw ExtensionPeerError.unavailable }
                try await navigation.navigate(request)
            }
            if worker == nil {
                do { backup = MusicBackupLifecycle(provider: try MusicBackupProvider.live()) } catch
                {
                    return ["ok": false, "error": error.localizedDescription] as NSDictionary
                }
                do { worker = try MusicWorker(admission: { nil }) } catch {
                    return ["ok": false, "error": error.localizedDescription] as NSDictionary
                }
            }
            if let worker, surface == nil {
                surface = MusicSurface(
                    read: worker.read, perform: worker.perform, readNotch: worker.readNotch,
                    readRetry: worker.retryNotch,
                    controlError: { [weak worker] in worker?.external.lastError },
                    version: Bundle(for: ExtensionRuntime.self).object(
                        forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
                    appIcon: worker.notchAppIcon)
                uiService = MusicUIService(
                    worker: worker,
                    version: Bundle(for: ExtensionRuntime.self).object(
                        forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
            }
            TextEditingCommands.install()
        case "configureUI":
            #if EDITH_FUNCTIONAL_FIXTURE
            do {
                let admission = try WorkerFixtureUIAdmission.current(
                    extensionID: "music", context: input,
                    roleBundle: Bundle(for: ExtensionRuntime.self))
                try admission?.requireCurrent()
                guard let admission else { return embeddedUI.configure(input) }
                guard let value = input["presentationID"] as? String,
                    let id = UUID(uuidString: value)
                else { throw WorkerFixtureError.invalid }
                let result = embeddedUI.configure(input) { [weak self] in
                    guard let self, self.admittedUI[id] === admission else { return }
                    self.admittedUI[id] = nil
                }
                if result["ok"] as? Bool == true { admittedUI[id] = admission }
                return result
            } catch { return ["ok": false] as NSDictionary }
            #else
            return embeddedUI.configure(input)
            #endif
        case "view":
            #if EDITH_FUNCTIONAL_FIXTURE
            do {
                let intent =
                    input["hostedFunctionalFixture"] != nil
                    || (input["hostIdentifier"] as? String)?.hasPrefix("com.pulkit.edith.tests.")
                        == true
                    || Bundle.main.bundleIdentifier?.hasPrefix("com.pulkit.edith.tests.") == true
                    || ProcessInfo.processInfo.environment["EDITH_EXTENSION_FIXTURE_HOME"] != nil
                if intent {
                    guard let value = input["presentationID"] as? String,
                        let id = UUID(uuidString: value), let admission = admittedUI[id]
                    else { throw WorkerFixtureError.invalid }
                    try admission.requireCurrent()
                }
            } catch { return ["ok": false] as NSDictionary }
            #endif
            guard let controller = embeddedUI.view(input) else {
                return ["ok": false] as NSDictionary
            }
            return controller
        case "releaseUI":
            _ = embeddedUI.release(input)
        case "stopUI": embeddedUI.stop()
        case "cancelCommand": commands.cancel(input["token"] as? String ?? "")
        case "synchronize": backup?.preferencesChanged()
        case "stop": _ = beginShutdown()
        case "status":
            return ["ok": true, "running": stopTask == nil && worker != nil] as NSDictionary
        default: return ["ok": false] as NSDictionary
        }
        return ["ok": true] as NSDictionary
    }
    private func beginShutdown() -> Task<Void, Never> {
        if let stopTask { return stopTask }
        let ownedWorker = worker
        let ownedService = uiService
        let ownedBackup = backup
        let ownedNavigation = navigation
        let hadLiveEngine = ownedWorker?.isInertFixture == false
        let hadUI = embeddedUI.presentationCount > 0
        commands.shutdown()
        embeddedUI.stop()
        ownedService?.stop()
        ownedWorker?.stop()
        ownedBackup?.beginShutdown()
        ownedNavigation?.invalidate()
        if hadLiveEngine {
            MusicHostNavigation.navigate = nil; MusicHostNavigation.reset()
        }
        if hadUI {
            EmbeddedMusicVideoSession.stopAll(); EmbeddedMusicBrowserSession.stopAll()
        }
        let task = Task {
            await commands.shutdownAndWait()
            await embeddedUI.stopAndWait()
            if hadUI {
                await EmbeddedMusicVideoSession.drainAll()
                await EmbeddedMusicBrowserSession.drainAll()
            }
            await ownedService?.drain()
            await ownedBackup?.shutdown()
            await ownedNavigation?.stopAndWait()
            await ownedWorker?.shutdown()
            navigation = nil; backup = nil; worker = nil; surface = nil; uiService = nil
            #if EDITH_FUNCTIONAL_FIXTURE
            engineFixture = nil; fixturePreferences = nil; admittedUI.removeAll()
            #endif
            if hadLiveEngine || hadUI {
                TextEditingCommands.shutdown(); InputFocus.uninstall()
            }
        }
        stopTask = task
        return task
    }

    #if EDITH_FUNCTIONAL_FIXTURE
    private func executeFixturePreferences(
        _ operation: String, payload: Data, token: UUID,
        admission: WorkerFixtureEngineAdmission
    ) throws -> Data {
        guard let preferences = fixturePreferences,
            ["music.ui.settings", "music.ui.action"].contains(operation)
        else { throw ExtensionPeerError.unavailable }
        let receipt = try admission.beginRequest(
            token: token, operation: operation, payload: payload)
        defer { admission.cancelRequest(receipt) }
        try Task.checkCancellation()
        let version =
            Bundle(for: ExtensionRuntime.self).object(
                forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let result = try preferences.executeFixture(
            operation, payload: payload, version: version,
            requireCurrent: admission.requireCurrent,
            invalidateHostSlots: MusicUIPreferenceEngine.invalidateHostSlots)
        try Task.checkCancellation()
        try admission.completeRequest(receipt)
        return result
    }

    #endif

}

@_cdecl("edith_extension_create")
public func createExtension() -> UnsafeMutableRawPointer? {
    UnsafeMutableRawPointer(
        bitPattern: MainActor.assumeIsolated {
            UInt(bitPattern: Unmanaged.passRetained(ExtensionRuntime()).toOpaque())
        })
}
