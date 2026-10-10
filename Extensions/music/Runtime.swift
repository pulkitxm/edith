import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import SwiftUI

@MainActor @objc(EdithMusicExtensionRuntime)
final class ExtensionRuntime: NSObject {
    private var worker: MusicWorker?
    private var surface: MusicSurface?
    private var uiService: MusicUIService?
    private var navigation: MusicHostNavigationBridge?
    private let embeddedUI = MusicEmbeddedRuntime()
    private var backup: MusicBackupLifecycle?
    private let commands = ExtensionCommandRegistry()
    private var inertFixture = false
    private let fixtureAdmission: (NSDictionary) throws -> WorkerFixtureAdmission?

    override init() {
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
        super.init()
    }

    init(fixtureAdmission: @escaping (NSDictionary) throws -> WorkerFixtureAdmission?) {
        self.fixtureAdmission = fixtureAdmission
        super.init()
    }

    @objc func invoke(_ request: NSDictionary, completion: @escaping (NSData?, NSString?) -> Void) {
        commands.invoke(request, completion: completion) { [weak self] command, payload in
            guard let self, self.worker != nil, !self.inertFixture else {
                throw ExtensionPeerError.unavailable
            }
            if command.hasPrefix("backup."), let backup = self.backup {
                return try await backup.execute(command, payload: payload)
            }
            if command.hasPrefix("music.ui.") || command == "music.cli" {
                guard let service = self.uiService else { throw ExtensionPeerError.unavailable }
                return try await service.execute(command, payload: payload)
            }
            guard let surface = self.surface else { throw ExtensionPeerError.unavailable }
            return try await surface.execute(command, payload: payload)
        }
    }

    @objc(prepareToStopWithCompletion:)
    func prepareToStop(completion: @escaping () -> Void) {
        if inertFixture {
            commands.shutdown()
            Task {
                await commands.shutdownAndWait()
                await worker?.shutdown(); worker = nil
                completion()
            }
            return
        }
        embeddedUI.stop()
        uiService?.stop()
        navigation?.invalidate(); MusicHostNavigation.navigate = nil; MusicHostNavigation.reset()
        commands.shutdown()
        backup?.beginShutdown()
        Task {
            await EmbeddedMusicVideoSession.drainAll()
            await EmbeddedMusicBrowserSession.drainAll()
            await uiService?.drain()
            await backup?.shutdown()
            await commands.shutdownAndWait()
            await navigation?.stopAndWait(); navigation = nil
            await worker?.shutdown()
            backup = nil; worker = nil; surface = nil; uiService = nil
            TextEditingCommands.shutdown(); InputFocus.uninstall()
            completion()
        }
    }

    @objc(prepareUIToClose:completion:)
    func prepareUIToClose(_ value: NSString, completion: @escaping (NSString?) -> Void) {
        guard let id = UUID(uuidString: value as String) else {
            completion("Invalid Music presentation."); return
        }
        Task {
            await embeddedUI.prepareToClose(id)
            completion(nil)
        }
    }

    @objc func execute(_ input: NSDictionary) -> NSObject {
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
            do {
                let fixture = try fixtureAdmission(input)
                if let fixture {
                    if worker == nil { worker = try MusicWorker(admission: { fixture }) }
                    inertFixture = true
                    return ["ok": true] as NSDictionary
                }
            } catch { return ["ok": false, "error": error.localizedDescription] as NSDictionary }
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
        case "configureUI": return embeddedUI.configure(input)
        case "view":
            guard let controller = embeddedUI.view(input) else {
                return ["ok": false] as NSDictionary
            }
            return controller
        case "releaseUI":
            _ = embeddedUI.release(input)
        case "stopUI": embeddedUI.stop()
        case "cancelCommand": commands.cancel(input["token"] as? String ?? "")
        case "synchronize": backup?.preferencesChanged()
        case "stop":
            if inertFixture {
                commands.shutdown(); worker?.stop(); worker = nil
                return ["ok": true] as NSDictionary
            }
            embeddedUI.stop()
            navigation?.invalidate(); navigation = nil; MusicHostNavigation.navigate = nil;
            MusicHostNavigation.reset()
            backup?.beginShutdown()
            uiService?.stop(); commands.shutdown(); worker?.stop(); worker = nil; surface = nil;
            uiService = nil
            TextEditingCommands.shutdown(); InputFocus.uninstall()
        case "status": return ["ok": true, "running": worker != nil] as NSDictionary
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
