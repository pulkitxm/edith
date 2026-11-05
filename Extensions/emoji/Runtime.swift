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
final class EmojiService: ExtensionService {
    private unowned let runtime: ExtensionServiceRuntime
    private var store: EmojiStore?
    private var observers: [NSObjectProtocol] = []
    private var presentation: ControlPresentation?
    private var fixture: WorkerFixtureAdmission?
    private var suspended = false
    private var retiredPresentations: [UUID: Task<Void, Never>] = [:]

    init(runtime: ExtensionServiceRuntime) { self.runtime = runtime }

    var isRunning: Bool { store != nil }

    func start(_ context: ExtensionHostContext) -> Bool {
        do {
            guard ExtensionEnvironment.values["EDITH_FUNCTIONAL_FIXTURE"] == nil,
                !context.isHostedFunctionalFixture
            else { return false }
            fixture = try WorkerFixtureAdmission.current(
                extensionID: "emoji", context: context.input,
                roleBundle: Bundle(for: EmojiService.self))
            return startStore()
        } catch { return false }
    }

    func synchronize() {
        registerHotKey()
        IPC.post(IPC.Name.settingsChanged)
    }

    func perform(_ operation: String, context: NSDictionary) -> NSObject? {
        if operation == "prepareToStop" { return runtime.execute(["operation": "stop"]) }
        guard operation == "pick" else { return nil }
        showPanel()
        return ["ok": true] as NSDictionary
    }

    func invoke(_ command: String, payload: Data) async throws -> Data {
        if command == "emoji.cli.catalog" {
            return try EmojiCLIExecution.catalog(payload)
        }
        if command == "emoji.cli" {
            let request = try JSONDecoder().decode(ExtensionCLIRequest.self, from: payload)
            if let help = try await EmojiCLIExecution.help(request) {
                return try JSONEncoder().encode(help)
            }
            guard let store = self.store else { throw ExtensionPeerError.unavailable }
            let reply = try await EmojiCLIExecution.run(
                request, defaults: SharedDefaults.store,
                catalog: store.catalog, pick: { self.showPanel() },
                insert: { try await store.insertAndWait(character: $0) },
                changed: { store.adoptSettings() })
            return try JSONEncoder().encode(reply)
        }
        if command.hasPrefix("emoji.ui.") {
            guard self.store != nil else { throw ExtensionPeerError.unavailable }
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
                guard action.value.isEmpty, let store = self.store else {
                    throw ExtensionPeerError.invalidRequest
                }
                switch action.action {
                case "pick": self.showPanel()
                case "clear": store.clearFrequent()
                default: throw ExtensionPeerError.invalidRequest
                }
            default: throw ExtensionPeerError.invalidRequest
            }
            return try ControlPresentationContract.snapshot(
                defaults: defaults, state: ControlPresentationState())
        }
        guard let store = self.store else { throw ExtensionPeerError.unavailable }
        return try await EmojiSurface.execute(
            command, payload: payload, store: store, pick: { self.showPanel() })
    }

    func configureUI(_ configuration: ExtensionUIConfiguration) -> Bool {
        guard !suspended, retiredPresentations.isEmpty,
            configuration.defaultsSuite
                == ExtensionEnvironment.values["EDITH_SHARED_DEFAULTS_SUITE"]
        else { return false }
        _ = retirePresentation()
        presentation = ControlPresentation(client: configuration.engineClient)
        return true
    }

    func view(for presentation: UUID) -> NSViewController? {
        guard let presentation = self.presentation else { return nil }
        return NSHostingController(
            rootView: ExtensionPageHost {
                ControlSettingsHost(presentation: presentation) {
                    Form { EmojiSettingsRows(presentation: presentation) }.settingsForm()
                }
            })
    }

    func stopUI() -> [Task<Void, Never>] {
        retirePresentation().map { [$0] } ?? []
    }

    func cancelPendingWork() {
        suspended = true
        presentation?.stop()
        let panel = fixture == nil ? EmojiPanel.shared : nil
        store?.shutdown()
        panel?.cancelPendingWork()
    }

    func drain() async {
        let panel = fixture == nil ? EmojiPanel.shared : nil
        await store?.drain()
        await panel?.drain()
        await presentation?.stopAndWait()
        await finishRetiredPresentations()
    }

    func teardown() async {
        let retiring = retirePresentation()
        if fixture == nil {
            EmojiPanel.shared.hide()
            EmojiPanel.shared.store = nil
        }
        store?.shutdown()
        store = nil
        observers.forEach(IPC.stopObserving)
        observers.removeAll()
        HotKeyRegistrar.shutdown()
        ExtensionUIResources.cleanup(of: runtime, key: "textEditing") {
            TextEditingCommands.shutdown()
        }
        await retiring?.value
        await finishRetiredPresentations()
    }

    private func startStore() -> Bool {
        guard !ExtensionHostRole.isInterfaceProcess, presentation == nil
        else { return false }
        guard store == nil else { return true }
        let created = EmojiStore(fixture: fixture)
        guard !created.catalog.emoji.isEmpty else { return false }
        store = created
        if fixture == nil { EmojiPanel.shared.store = created }
        if fixture == nil {
            HotKeyRegistrar.configure(
                ExtensionHotKeyBinding(
                    id: HotKeyCatalog.emoji, prefix: "emojiHotKey",
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
                        self?.store?.insert(character: character) { inserted in
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

    private func retirePresentation() -> Task<Void, Never>? {
        guard let presentation else { return nil }
        presentation.stop()
        let id = UUID()
        let task = Task { [self, presentation] in
            defer { retiredPresentations[id] = nil }
            await presentation.stopAndWait()
        }
        retiredPresentations[id] = task
        self.presentation = nil
        return task
    }

    private func finishRetiredPresentations() async {
        while let task = retiredPresentations.values.first { await task.value }
    }

    private func showPanel() {
        guard !suspended, fixture == nil else { return }
        EmojiPanel.shared.toggle()
    }

    private func registerHotKey() {
        guard !suspended, fixture == nil else { return }
        HotKeyRegistrar.install(HotKeyCatalog.emoji) { [weak self] in
            guard self?.suspended == false else { return }
            EmojiPanel.shared.toggle()
        }
    }
}

@MainActor
func makeEmojiRuntime() -> ExtensionServiceRuntime {
    final class BundleAnchor {}
    return ExtensionServiceRuntime(
        id: "emoji", role: "helper", bundle: Bundle(for: BundleAnchor.self)
    ) { EmojiService(runtime: $0) }
}

@_cdecl("edith_extension_create")
public func createExtension() -> UnsafeMutableRawPointer? {
    UnsafeMutableRawPointer(
        bitPattern: MainActor.assumeIsolated {
            UInt(bitPattern: Unmanaged.passRetained(makeEmojiRuntime()).toOpaque())
        })
}
