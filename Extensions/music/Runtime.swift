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
final class MusicService: ExtensionService {
    private unowned let runtime: ExtensionServiceRuntime
    private var worker: MusicWorker?
    private var surface: MusicSurface?
    private var uiService: MusicUIService?
    private var navigation: MusicHostNavigationBridge?
    private let embeddedUI = MusicEmbeddedRuntime()
    private var backup: MusicBackupLifecycle?
    private var inertFixture = false
    private var hadLiveEngine = false
    private var hadUI = false
    private let fixtureAdmission: (NSDictionary) throws -> WorkerFixtureAdmission?

    init(
        runtime: ExtensionServiceRuntime,
        fixtureAdmission: ((NSDictionary) throws -> WorkerFixtureAdmission?)? = nil
    ) {
        self.runtime = runtime
        self.fixtureAdmission =
            fixtureAdmission ?? { input in
                try MusicWorker.resolveFixture(
                    admission: {
                        try WorkerFixtureAdmission.current(
                            extensionID: "music", context: input,
                            roleBundle: Bundle(for: MusicService.self))
                    },
                    applicationIdentifier: ExtensionEnvironment.values[
                        "EDITH_APPLICATION_IDENTIFIER"])
            }
    }

    var isRunning: Bool { worker != nil }

    var preparesUIToClose: Bool { true }

    func start(_ context: ExtensionHostContext) -> Bool {
        let input = context.input
        do {
            let fixture = try fixtureAdmission(input)
            if let fixture {
                if worker == nil { worker = try MusicWorker(admission: { fixture }) }
                inertFixture = true
                return true
            }
        } catch { return false }
        do {
            guard
                try WorkerFixtureAdmission.current(
                    extensionID: "music", context: input,
                    roleBundle: Bundle(for: MusicService.self)) == nil
            else { return false }
        } catch { return false }
        guard !ExtensionHostRole.isInterfaceProcess, SurfaceHostContext.current != nil
        else { return false }
        if navigation == nil {
            navigation = MusicHostNavigationBridge(bridge: input["hostNavigation"] as? NSObject)
        }
        MusicHostNavigation.navigate = { [weak navigation] request in
            guard let navigation else { throw ExtensionPeerError.unavailable }
            try await navigation.navigate(request)
        }
        if worker == nil {
            do { backup = MusicBackupLifecycle(provider: try MusicBackupProvider.live()) } catch {
                return false
            }
            do { worker = try MusicWorker(admission: { nil }) } catch { return false }
        }
        if let worker, surface == nil {
            let version =
                Bundle(for: MusicService.self).object(
                    forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
            surface = MusicSurface(
                read: worker.read, perform: worker.perform, readNotch: worker.readNotch,
                readRetry: worker.retryNotch,
                controlError: { [weak worker] in worker?.external.lastError },
                version: version, appIcon: worker.notchAppIcon)
            uiService = MusicUIService(worker: worker, version: version)
        }
        TextEditingCommands.install()
        return true
    }

    func synchronize(_ context: ExtensionHostContext) -> Bool {
        guard !runtime.isStopping else { return false }
        backup?.preferencesChanged()
        return true
    }

    func invoke(_ command: String, payload: Data) async throws -> Data {
        guard worker != nil, !inertFixture else { throw ExtensionPeerError.unavailable }
        if command.hasPrefix("backup."), let backup {
            return try await backup.execute(command, payload: payload)
        }
        if command == "music.cli.catalog" {
            return try ExtensionCLICatalog.data(
                MusicCommand.self, owner: "music", payload: payload, streaming: false)
        }
        if command.hasPrefix("music.ui.") || command == "music.cli" {
            guard let uiService else { throw ExtensionPeerError.unavailable }
            return try await uiService.execute(command, payload: payload)
        }
        guard let surface else { throw ExtensionPeerError.unavailable }
        return try await surface.execute(command, payload: payload)
    }

    func configureUI(_ configuration: ExtensionUIConfiguration) -> Bool {
        guard !inertFixture else { return false }
        return embeddedUI.configure(configuration.input)["ok"] as? Bool == true
    }

    func view(for presentation: UUID, context: ExtensionHostContext) -> NSViewController? {
        guard !runtime.isStopping, !inertFixture else { return nil }
        return embeddedUI.view(context.input)
    }

    func perform(_ operation: String, context: NSDictionary) -> NSObject? {
        guard operation == "releaseUI", !inertFixture else { return nil }
        _ = embeddedUI.release(context)
        return ["ok": true] as NSDictionary
    }

    func acceptsStopUI(for presentation: UUID?) -> Bool { !inertFixture }

    func stopUI(for presentation: UUID?) -> [Task<Void, Never>] {
        embeddedUI.stop()
        return []
    }

    func prepareUIToClose(_ presentation: UUID) async -> String? {
        await embeddedUI.prepareToClose(presentation)
    }

    func cancelPendingWork() {
        embeddedUI.suspendCommands()
        backup?.suspendCommands()
    }

    func drain() async {
        await embeddedUI.suspendCommandsAndWait()
        await backup?.suspendCommandsAndWait()
    }

    func finishBeforeStop() async {
        hadLiveEngine = worker?.isInertFixture == false
        hadUI = embeddedUI.presentationCount > 0
        embeddedUI.stop()
        uiService?.stop()
        worker?.stop()
        backup?.beginShutdown()
        navigation?.invalidate()
        if hadLiveEngine {
            MusicHostNavigation.navigate = nil
            MusicHostNavigation.reset()
        }
        if hadUI {
            EmbeddedMusicVideoSession.stopAll()
            EmbeddedMusicBrowserSession.stopAll()
        }
    }

    func teardown() async {
        let ownedWorker = worker
        let ownedService = uiService
        let ownedBackup = backup
        let ownedNavigation = navigation
        await embeddedUI.stopAndWait()
        if hadUI {
            await EmbeddedMusicVideoSession.drainAll()
            await EmbeddedMusicBrowserSession.drainAll()
        }
        await ownedService?.drain()
        await ownedBackup?.shutdown()
        await ownedNavigation?.stopAndWait()
        await ownedWorker?.shutdown()
        navigation = nil
        backup = nil
        worker = nil
        surface = nil
        uiService = nil
        if hadLiveEngine || hadUI {
            ExtensionUIResources.cleanup(of: runtime, key: "textEditing") {
                TextEditingCommands.shutdown()
            }
            InputFocus.uninstall()
        }
    }
}

@MainActor
func makeMusicRuntime(
    fixtureAdmission: ((NSDictionary) throws -> WorkerFixtureAdmission?)? = nil
) -> ExtensionServiceRuntime {
    final class BundleAnchor {}
    return ExtensionServiceRuntime(
        id: "music", role: "app", bundle: Bundle(for: BundleAnchor.self)
    ) { MusicService(runtime: $0, fixtureAdmission: fixtureAdmission) }
}

@_cdecl("edith_extension_create")
public func createExtension() -> UnsafeMutableRawPointer? {
    UnsafeMutableRawPointer(
        bitPattern: MainActor.assumeIsolated {
            UInt(bitPattern: Unmanaged.passRetained(makeMusicRuntime()).toOpaque())
        })
}
