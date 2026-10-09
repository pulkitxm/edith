import AppKit
import Carbon.HIToolbox
import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import SwiftUI

@MainActor
final class ExtensionRuntime: NSObject {
    private var service: EmojiStore?
    private var observers: [NSObjectProtocol] = []

    private let commands = ExtensionCommandRegistry()

    @objc func invoke(_ request: NSDictionary, completion: @escaping (NSData?, NSString?) -> Void) {
        commands.invoke(request, completion: completion) { [weak self] command, payload in
            guard let self, let service = self.service else { throw ExtensionPeerError.unavailable }
            return try await SurfaceCommandService.execute(
                providerID: "emoji", command: command, payload: payload,
                snapshot: { _ in
                    EmojiSurface.snapshot(frequent: service.frequent, character: service.character)
                },
                perform: { action in
                    if action == "pick" {
                        EmojiPanel.shared.show()
                    } else if let emoji = service.frequent.first(where: {
                        "copy:" + $0.id == action
                    }) {
                        service.copy(emoji)
                    } else {
                        throw ExtensionPeerError.invalidRequest
                    }
                })
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
        case "start":
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
            return NSHostingController(
                rootView: ExtensionPageHost {
                    PageWorkspace {
                        PageHeader("Emoji")
                    } content: {
                        Form { EmojiSettingsRows() }.formStyle(.grouped)
                    }
                })
        case "pick": EmojiPanel.shared.show()
        case "synchronize":
            registerHotKey()
            IPC.post(IPC.Name.settingsChanged)
        case "cancelCommand": commands.cancel(input["token"] as? String ?? "")
        case "stop":
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
