import AppKit
import Carbon.HIToolbox
import EdithExtensionSupport
import EdithExtensionCommands
import EdithExtensionUI
import Foundation
import SwiftUI

@MainActor
final class ExtensionRuntime: NSObject {
    private var service: EmojiStore?
    private var observers: [NSObjectProtocol] = []

    private var presentation: ControlPresentation?

    private let commands = ExtensionCommandRegistry()

    @objc func invoke(_ request: NSDictionary, completion: @escaping (NSData?, NSString?) -> Void) {
        commands.invoke(request, completion: completion) { [weak self] command, payload in
            if command == "emoji.cli.catalog" {
                return try EmojiCLIExecution.catalog(payload)
            }
            if command == "emoji.cli" {
                guard let self, self.service != nil else { throw ExtensionPeerError.unavailable }
                guard let service = self.service else { throw ExtensionPeerError.unavailable }
                let request = try JSONDecoder().decode(ExtensionCLIRequest.self, from: payload)
                let reply = try await EmojiCLIExecution.run(
                    request, defaults: SharedDefaults.store,
                    catalog: service.catalog, pick: { EmojiPanel.shared.show() },
                    insert: { try await service.insertAndWait(character: $0) },
                    changed: { service.adoptSettings() })
                return try JSONEncoder().encode(reply)
            }
            if command.hasPrefix("emoji.ui.") {
                guard let self, self.service != nil else { throw ExtensionPeerError.unavailable }
                let defaults = SharedDefaults.store
                switch command {
                case "emoji.ui.read":
                    guard payload == Data("{}".utf8) else {
                        throw ExtensionPeerError.invalidRequest
                    }
                case "emoji.ui.update":
                    try ControlPresentationContract.update(payload, defaults: defaults)
                    self.registerHotKey()
                    IPC.post(IPC.Name.settingsChanged)
                case "emoji.ui.action":
                    let action = try JSONDecoder().decode(
                        ControlPresentationAction.self, from: payload)
                    guard action.value.isEmpty, let service = self.service else {
                        throw ExtensionPeerError.invalidRequest
                    }
                    switch action.action {
                    case "pick": EmojiPanel.shared.show()
                    case "clear": service.clearFrequent()
                    default: throw ExtensionPeerError.invalidRequest
                    }
                default: throw ExtensionPeerError.invalidRequest
                }
                return try ControlPresentationContract.snapshot(
                    defaults: defaults, state: ControlPresentationState())
            }
            guard let self, let service = self.service else { throw ExtensionPeerError.unavailable }
            return try await EmojiSurface.execute(
                command, payload: payload, store: service, pick: { EmojiPanel.shared.show() })
        }
    }

    @objc(prepareToStopWithCompletion:)
    func prepareToStop(completion: @escaping () -> Void) {
        Task {
            await commands.shutdownAndWait()
            _ = execute(["operation": "stop"])
            completion()
        }
    }

    @objc func execute(_ input: NSDictionary) -> NSObject {
        switch input["operation"] as? String {
        case "describe":
            let bundle = Bundle(for: ExtensionRuntime.self)
            return [
                "id": "emoji", "role": "helper",
                "version": bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                    as? String ?? "",
                "hostABI": bundle.object(forInfoDictionaryKey: "EdithHostABI") as? String ?? "",
            ] as NSDictionary
        case "configureUI":
            guard let configuration = ExtensionUIConfiguration(context: input),
                configuration.extensionID == "emoji",
                configuration.defaultsSuite
                    == ProcessInfo.processInfo.environment["EDITH_SHARED_DEFAULTS_SUITE"]
            else { return ["ok": false] as NSDictionary }
            presentation?.stop()
            presentation = ControlPresentation(client: configuration.engineClient)
            return ["ok": true] as NSDictionary
        case "stopUI":
            presentation?.stop()
            presentation = nil
            return ["ok": true] as NSDictionary
        case "prepareToStop":
            commands.shutdown()
            return ["ok": true] as NSDictionary
        case "start":
            guard Bundle.main.bundleURL.pathExtension != "appex", presentation == nil
            else { return ["ok": false] as NSDictionary }
            guard let suite = input["defaultsSuite"] as? String,
                suite == ProcessInfo.processInfo.environment["EDITH_SHARED_DEFAULTS_SUITE"]
            else { return ["ok": false] as NSDictionary }
            guard service == nil else { return ["ok": true] as NSDictionary }
            let store = EmojiStore()
            guard !store.catalog.emoji.isEmpty else { return ["ok": false] as NSDictionary }
            service = store
            EmojiPanel.shared.store = store
            HotKeyRegistrar.configure(
                ExtensionHotKeyBinding(
                    id: HotKeyCatalog.emoji, carbonID: 8, prefix: "emojiHotKey",
                    defaultCode: kVK_ANSI_E, defaultModifiers: controlKey | shiftKey))
            registerHotKey()
            observers.append(
                IPC.observe(IPC.Name.settingsChanged) { [weak self] in
                    MainActor.assumeIsolated { self?.registerHotKey() }
                })
            observers.append(
                IPC.observe(IPC.Name.requestEmojiPanel) {
                    MainActor.assumeIsolated { EmojiPanel.shared.show() }
                })
            observers.append(
                NotificationCenter.default.addObserver(
                    forName: Notification.Name(IPC.Name.requestEmojiInsert), object: nil,
                    queue: .main
                ) { [weak self] notification in
                    guard
                        let character = notification.userInfo?[EmojiInsertIPC.characterKey]
                            as? String
                    else { return }
                    let requestID = notification.userInfo?[EmojiInsertIPC.requestIDKey] as? String
                    MainActor.assumeIsolated {
                        self?.service?.insert(character: character) { inserted in
                            guard let requestID else { return }
                            IPC.post(
                                IPC.Name.emojiInsertResult,
                                userInfo: EmojiInsertIPC.resultPayload(
                                    requestID: requestID, inserted: inserted))
                        }
                    }
                })
        case "view":
            guard let presentation else { return ["ok": false] as NSDictionary }
            return NSHostingController(
                rootView: ExtensionPageHost {
                    ControlSettingsHost(presentation: presentation) {
                        PageWorkspace {
                            PageHeader("Emoji")
                        } content: {
                            Form { EmojiSettingsRows(presentation: presentation) }.formStyle(
                                .grouped)
                        }
                    }
                })
        case "pick": EmojiPanel.shared.show()
        case "synchronize":
            registerHotKey()
            IPC.post(IPC.Name.settingsChanged)
        case "cancelCommand": commands.cancel(input["token"] as? String ?? "")
        case "stop":
            presentation?.stop()
            presentation = nil
            commands.shutdown()
            EmojiPanel.shared.hide()
            EmojiPanel.shared.store = nil
            service?.shutdown()
            service = nil
            observers.forEach(IPC.stopObserving)
            observers.removeAll()
            HotKeyRegistrar.shutdown()
            TextEditingCommands.shutdown()
        case "status": return ["ok": true, "running": service != nil] as NSDictionary
        default: return ["ok": false] as NSDictionary
        }
        return ["ok": true] as NSDictionary
    }

    private func registerHotKey() {
        HotKeyRegistrar.install(HotKeyCatalog.emoji) { EmojiPanel.shared.toggle() }
    }
}

@_cdecl("edith_extension_create")
public func createExtension() -> UnsafeMutableRawPointer? {
    UnsafeMutableRawPointer(
        bitPattern: MainActor.assumeIsolated {
            UInt(bitPattern: Unmanaged.passRetained(ExtensionRuntime()).toOpaque())
        })
}
