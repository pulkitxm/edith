#if canImport(WorkerFixtureSupport)
import WorkerFixtureSupport
#endif
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

    private var fixture: WorkerFixtureAdmission?
    private var engineAdmission: WorkerFixtureEngineAdmission?
    private let commands = ExtensionCommandRegistry()
    private var suspended = false
    private var suspension: Task<Void, Never>?
    private var retiredPresentations: [UUID: Task<Void, Never>] = [:]

    @objc func invoke(_ request: NSDictionary, completion: @escaping (NSData?, NSString?) -> Void) {
        let token = (request["token"] as? String).flatMap { UUID(uuidString: $0) }
        let admission = engineAdmission
        commands.invoke(request, completion: completion) { [weak self] command, payload in
            guard let self, let token, self.engineAdmission === admission else {
                throw ExtensionPeerError.unavailable
            }
            let admitted = try admission?.beginRequest(
                token: token, operation: command, payload: payload)
            defer {
                if let admitted { admission?.cancelRequest(admitted) }
            }
            let reply = try await self.executeCommand(command, payload: payload)
            if let admitted { try admission?.completeRequest(admitted) }
            return reply
        }
    }

    private func executeCommand(_ command: String, payload: Data) async throws -> Data {
        if command == "emoji.cli.catalog" {
            return try EmojiCLIExecution.catalog(payload)
        }
        if command == "emoji.cli" {
            let request = try JSONDecoder().decode(ExtensionCLIRequest.self, from: payload)
            if let help = try await EmojiCLIExecution.help(request) {
                return try JSONEncoder().encode(help)
            }
            guard self.service != nil else { throw ExtensionPeerError.unavailable }
            guard let service = self.service else { throw ExtensionPeerError.unavailable }
            let reply = try await EmojiCLIExecution.run(
                request, defaults: SharedDefaults.store,
                catalog: service.catalog, pick: { self.showPanel() },
                insert: { try await service.insertAndWait(character: $0) },
                changed: { service.adoptSettings() })
            return try JSONEncoder().encode(reply)
        }
        if command.hasPrefix("emoji.ui.") {
            guard self.service != nil else { throw ExtensionPeerError.unavailable }
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
                case "pick": self.showPanel()
                case "clear": service.clearFrequent()
                default: throw ExtensionPeerError.invalidRequest
                }
            default: throw ExtensionPeerError.invalidRequest
            }
            return try ControlPresentationContract.snapshot(
                defaults: defaults, state: ControlPresentationState())
        }
        guard let service = self.service else { throw ExtensionPeerError.unavailable }
        return try await EmojiSurface.execute(
            command, payload: payload, store: service, pick: { self.showPanel() })
    }

    @objc(suspendCommandsWithCompletion:)
    func suspendCommands(completion: @escaping () -> Void) {
        commands.suspend()
        suspended = true
        let service = service
        let presentation = presentation
        presentation?.stop()
        let panel = fixture == nil ? EmojiPanel.shared : nil
        service?.shutdown()
        panel?.cancelPendingWork()
        if suspension == nil {
            let presentations = Array(retiredPresentations.values)
            suspension = Task { [self, service, panel, presentation] in
                await commands.suspendAndWait()
                await service?.drain()
                await panel?.drain()
                await presentation?.stopAndWait()
                for task in presentations { await task.value }
            }
        }
        let pending = suspension
        Task { [self] in
            await pending?.value
            withExtendedLifetime(self) { completion() }
        }
    }

    @objc(prepareToStopWithCompletion:)
    func prepareToStop(completion: @escaping () -> Void) {
        suspendCommands { [self] in
            Task { [self] in
                await commands.shutdownAndWait()
                _ = execute(["operation": "stop"])
                for task in Array(retiredPresentations.values) { await task.value }
                completion()
            }
        }
    }

    private func startService(_ input: NSDictionary) -> Bool {
        guard Bundle.main.bundleURL.pathExtension != "appex", presentation == nil
        else { return false }
        guard let suite = input["defaultsSuite"] as? String,
            suite == ProcessInfo.processInfo.environment["EDITH_SHARED_DEFAULTS_SUITE"]
        else { return false }
        guard service == nil else { return true }
        let store = EmojiStore(fixture: fixture)
        guard !store.catalog.emoji.isEmpty else { return false }
        service = store
        if fixture == nil { EmojiPanel.shared.store = store }
        if fixture == nil {
            HotKeyRegistrar.configure(
                ExtensionHotKeyBinding(
                    id: HotKeyCatalog.emoji, carbonID: 8, prefix: "emojiHotKey",
                    defaultCode: kVK_ANSI_E, defaultModifiers: controlKey | shiftKey))
        }
        registerHotKey()
        observers.append(
            IPC.observe(IPC.Name.settingsChanged) { [weak self] in
                MainActor.assumeIsolated { self?.registerHotKey() }
            })
        if fixture == nil {
            observers.append(
                IPC.observe(IPC.Name.requestEmojiPanel) { [weak self] in
                    MainActor.assumeIsolated { self?.showPanel() }
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
                    let requestID =
                        notification.userInfo?[EmojiInsertIPC.requestIDKey] as? String
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
        }
        return true
    }

    private func retirePresentation() {
        guard let presentation else { return }
        presentation.stop()
        let id = UUID()
        retiredPresentations[id] = Task { [self, presentation] in
            await presentation.stopAndWait()
            retiredPresentations[id] = nil
        }
        self.presentation = nil
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
            guard !suspended, retiredPresentations.isEmpty,
                let configuration = ExtensionUIConfiguration(context: input),
                configuration.extensionID == "emoji",
                configuration.defaultsSuite
                    == ProcessInfo.processInfo.environment["EDITH_SHARED_DEFAULTS_SUITE"]
            else { return ["ok": false] as NSDictionary }
            retirePresentation()
            presentation = ControlPresentation(client: configuration.engineClient)
            return ["ok": true] as NSDictionary
        case "stopUI":
            retirePresentation()
            return ["ok": true] as NSDictionary
        case "prepareToStop":
            commands.shutdown()
            return ["ok": true] as NSDictionary
        case "start":
            guard !suspended else { return ["ok": false] as NSDictionary }
            do {
                let admission = try WorkerFixtureEngineAdmission.current(
                    extensionID: "emoji", context: input,
                    roleBundle: Bundle(for: ExtensionRuntime.self), expectedRole: .helper)
                engineAdmission = admission
                let started: Bool
                if let admission {
                    started = try admission.withPlatformFixture(
                        extensionID: "emoji", expectedRole: .helper
                    ) { namespace in
                        fixture = namespace
                        return startService(input)
                    }
                } else {
                    fixture = nil
                    started = startService(input)
                }
                return ["ok": started] as NSDictionary
            } catch { return ["ok": false] as NSDictionary }
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
        case "pick":
            do { try engineAdmission?.requireCurrent() } catch {
                return ["ok": false] as NSDictionary
            }
            self.showPanel()
        case "synchronize":
            do { try engineAdmission?.requireCurrent() } catch {
                return ["ok": false] as NSDictionary
            }
            registerHotKey()
            IPC.post(IPC.Name.settingsChanged)
        case "cancelCommand": commands.cancel(input["token"] as? String ?? "")
        case "stop":
            suspendCommands(completion: {})
            retirePresentation()
            commands.shutdown()
            if fixture == nil { EmojiPanel.shared.hide(); EmojiPanel.shared.store = nil }
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

    private func showPanel() {
        guard !suspended, fixture == nil else { return }
        EmojiPanel.shared.show()
    }

    private func registerHotKey() {
        guard !suspended, fixture == nil else { return }
        HotKeyRegistrar.install(HotKeyCatalog.emoji) { [weak self] in
            guard self?.suspended == false else { return }
            EmojiPanel.shared.toggle()
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
