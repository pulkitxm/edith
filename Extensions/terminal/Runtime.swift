import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import GhosttyTerminal
import SwiftUI

@MainActor @objc(EdithTerminalExtensionRuntime)
final class ExtensionRuntime: NSObject {
    private var engine: TerminalEngine?
    private var surface: TerminalSurface?
    private struct Presentation {
        let model: TerminalTabsModel
        var controller: NSViewController?
        var events: TerminalUIEventTracker
    }
    private var presentations: [UUID: Presentation] = [:]
    private let commands = ExtensionCommandRegistry()
    private let makeEngine: @MainActor () -> TerminalEngine

    override init() {
        makeEngine = { TerminalEngine() }
        super.init()
    }

    init(makeEngine: @escaping @MainActor () -> TerminalEngine) {
        self.makeEngine = makeEngine
        super.init()
    }

    @objc func invoke(_ request: NSDictionary, completion: @escaping (NSData?, NSString?) -> Void) {
        commands.invoke(request, completion: completion) { [weak self] command, payload in
            guard let self, let engine = self.engine else { throw ExtensionPeerError.unavailable }
            if command.hasPrefix("surface.") {
                guard let surface = self.surface else { throw ExtensionPeerError.unavailable }
                return try await surface.execute(command, payload: payload)
            }
            return try await engine.execute(command, payload: payload)
        }
    }

    @objc(prepareToStopWithCompletion:)
    func prepareToStop(completion: @escaping () -> Void) {
        Task {
            await commands.shutdownAndWait()
            stopEngine()
            completion()
        }
    }

    @objc func execute(_ input: NSDictionary) -> AnyObject {
        switch input["operation"] as? String {
        case "describe":
            let bundle = Bundle(for: ExtensionRuntime.self)
            return [
                "id": "terminal", "role": "app",
                "version": bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                    as? String ?? "",
                "hostABI": bundle.object(forInfoDictionaryKey: "EdithHostABI") as? String ?? "",
            ] as NSDictionary
        case "start":
            guard Bundle.main.bundleURL.pathExtension != "appex",
                let suite = input["defaultsSuite"] as? String,
                suite == ProcessInfo.processInfo.environment["EDITH_SHARED_DEFAULTS_SUITE"]
            else { return ["ok": false] as NSDictionary }
            if engine == nil {
                let engine = makeEngine()
                self.engine = engine
                surface = TerminalSurface(engine: engine)
            }
        case "configureUI":
            guard let configuration = ExtensionUIConfiguration(context: input),
                configuration.extensionID == "terminal", !configuration.uiOnly,
                let client = configuration.engineClient
            else { return ["ok": false] as NSDictionary }
            let id = client.presentationID
            guard presentations[id] != nil || presentations.count < 16 else {
                client.invalidate()
                return ["ok": false] as NSDictionary
            }
            presentations[id]?.model.stopAll()
            presentations[id] = Presentation(
                model: TerminalTabsModel(client: TerminalRemoteClient(client: client)),
                events: TerminalUIEventTracker(presentationID: id))
            TextEditingCommands.install()
        case "view":
            guard let value = input["presentationID"] as? String, let id = UUID(uuidString: value),
                var presentation = presentations[id]
            else { return ["ok": false] as NSDictionary }
            if let controller = presentation.controller { return controller }
            let model = presentation.model
            let controller = NSHostingController(
                rootView: ExtensionPageHost {
                    TerminalPage(model: model, onWindowClose: { model.windowClosed() })
                })
            presentation.controller = controller
            presentations[id] = presentation
            return controller
        case "terminalUI":
            guard let data = input["payload"] as? Data,
                let value = input["presentationID"] as? String, let id = UUID(uuidString: value),
                var presentation = presentations[id],
                let event = try? presentation.events.accept(data)
            else { return ["ok": false] as NSDictionary }
            presentations[id] = presentation
            return ["ok": presentation.model.applyUIEvent(event)] as NSDictionary
        case "terminalUIStatus":
            guard let value = input["presentationID"] as? String, let id = UUID(uuidString: value),
                let presentation = presentations[id]
            else { return ["ok": false] as NSDictionary }
            return [
                "ok": true,
                "focused": presentation.model.selectedTab?.holder.ghosttyView?.hasInputFocus
                    == true,
                "presentationID": id.uuidString,
            ] as NSDictionary
        case "cancelCommand": commands.cancel(input["token"] as? String ?? "")
        case "synchronize":
            for presentation in presentations.values { presentation.model.synchronize() }
        case "stopUI":
            if let value = input["presentationID"] as? String {
                guard let id = UUID(uuidString: value), presentations[id] != nil else {
                    return ["ok": false] as NSDictionary
                }
                stopUI(id)
            } else {
                stopUI()
            }
        case "stop":
            stopUI()
            commands.shutdown()
            stopEngine()
        case "status": return ["ok": true, "running": engine?.isStopped == false] as NSDictionary
        default: return ["ok": false] as NSDictionary
        }
        return ["ok": true] as NSDictionary
    }

    private func stopUI(_ id: UUID? = nil) {
        guard !presentations.isEmpty else { return }
        for identifier in id.map({ [$0] }) ?? Array(presentations.keys) {
            presentations.removeValue(forKey: identifier)?.model.stopAll()
        }
        if presentations.isEmpty {
            GhosttyRuntime.shared.shutdown()
            TextEditingCommands.shutdown()
        }
    }

    private func stopEngine() {
        engine?.stop()
        engine = nil
        surface = nil
    }
}

@_cdecl("edith_extension_create")
public func createExtension() -> UnsafeMutableRawPointer? {
    UnsafeMutableRawPointer(
        bitPattern: MainActor.assumeIsolated {
            UInt(bitPattern: Unmanaged.passRetained(ExtensionRuntime()).toOpaque())
        })
}
