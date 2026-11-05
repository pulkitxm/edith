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
final class ColorPickerService: ExtensionService {
    private unowned let runtime: ExtensionServiceRuntime
    private var store: ColorPickerStore?
    private var observer: NSObjectProtocol?
    private var presentation: ControlPresentation?
    private var fixture: WorkerFixtureAdmission?
    private var uiDrains: [UUID: Task<Void, Never>] = [:]
    private var suspended = false

    init(runtime: ExtensionServiceRuntime) { self.runtime = runtime }

    var isRunning: Bool { observer != nil }
    var allowsUIDuringRetirement: Bool { true }

    private var environmentFixtureActive: Bool {
        ExtensionEnvironment.values["EDITH_FUNCTIONAL_FIXTURE"] != nil
    }

    func start(_ context: ExtensionHostContext) -> Bool {
        guard !ExtensionHostRole.isInterfaceProcess, presentation == nil,
            !environmentFixtureActive, !context.isHostedFunctionalFixture
        else { return false }
        let admission: WorkerFixtureAdmission?
        do {
            admission = try WorkerFixtureAdmission.current(
                extensionID: "colorPicker", context: context.input,
                roleBundle: Bundle(for: ColorPickerService.self))
        } catch { return false }
        if admission == nil {
            HotKeyRegistrar.configure(
                ExtensionHotKeyBinding(
                    id: HotKeyCatalog.colorPicker,
                    prefix: "colorPickerHotKey", defaultCode: kVK_ANSI_C,
                    defaultModifiers: cmdKey | optionKey | controlKey))
        }
        SharedDefaults.store.set(true, forKey: AppStorageKeys.ColorPicker.enabled)
        let owner = store ?? ColorPickerStore(fixture: admission)
        owner.registerHotKey()
        store = owner
        fixture = admission
        if observer == nil {
            observer = IPC.observe(IPC.Name.settingsChanged) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, !self.environmentFixtureActive else { return }
                    self.store?.registerHotKey()
                }
            }
        }
        return true
    }

    func synchronize(_ context: ExtensionHostContext) -> Bool {
        guard !suspended, !environmentFixtureActive, !context.isHostedFunctionalFixture else {
            return false
        }
        store?.registerHotKey()
        return true
    }

    func perform(_ operation: String, context: NSDictionary) -> NSObject? {
        if operation == "prepareToStop" { return runtime.execute(["operation": "stop"]) }
        guard operation == "pick" else { return nil }
        guard !suspended, !environmentFixtureActive, context["hostedFunctionalFixture"] == nil
        else { return nil }
        store?.pick()
        return ["ok": true] as NSDictionary
    }

    func invoke(_ command: String, payload: Data) async throws -> Data {
        guard !environmentFixtureActive else {
            throw ExtensionPeerError.rejected("The functional fixture is unavailable.")
        }
        try Task.checkCancellation()
        if command == "colorPicker.cli.catalog" {
            return try ColorCLIExecution.catalog(payload)
        }
        if command == "colorPicker.cli" {
            let request = try JSONDecoder().decode(ExtensionCLIRequest.self, from: payload)
            if let help = try await ColorCLIExecution.help(request) {
                return try JSONEncoder().encode(help)
            }
            let store = self.store
            if request.arguments.first == "pick", store == nil {
                throw ExtensionPeerError.unavailable
            }
            let reply = try await ColorCLIExecution.run(
                request, defaults: SharedDefaults.store,
                pick: { store?.pick() },
                write: { value in
                    if self.fixture != nil { return store?.writeFixtureCopy(value) ?? false }
                    NSPasteboard.general.clearContents()
                    return NSPasteboard.general.setString(value, forType: .string)
                }, changed: { store?.reloadHistory() })
            return try JSONEncoder().encode(reply)
        }
        if command.hasPrefix("colorPicker.ui.") {
            guard self.store != nil else { throw ExtensionPeerError.unavailable }
            let defaults = SharedDefaults.store
            switch command {
            case "colorPicker.ui.read":
                guard payload == Data("{}".utf8) else {
                    throw ExtensionPeerError.invalidRequest
                }
            case "colorPicker.ui.update":
                try ControlPresentationContract.update(payload, defaults: defaults)
                self.store?.registerHotKey()
            case "colorPicker.ui.action":
                let action = try JSONDecoder().decode(
                    ControlPresentationAction.self, from: payload)
                guard let store = self.store else { throw ExtensionPeerError.unavailable }
                if action.action == "pick", action.value.isEmpty {
                    store.pick()
                } else if action.action == "copy",
                    let pair = action.value.split(separator: ":").first,
                    let swatch = store.history.first(where: {
                        $0.id.uuidString == String(pair)
                    }),
                    let format = action.value.split(separator: ":").last.flatMap({
                        ColorCopyFormat(rawValue: String($0))
                    }),
                    action.value == swatch.id.uuidString + ":" + format.rawValue
                {
                    store.copy(swatch, as: format)
                    if let error = store.copyError {
                        throw ExtensionPeerError.rejected(error)
                    }
                } else {
                    throw ExtensionPeerError.invalidRequest
                }
            default: throw ExtensionPeerError.invalidRequest
            }
            return try ControlPresentationContract.snapshot(
                defaults: defaults, state: ControlPresentationState())
        }
        guard let store = self.store else { throw ExtensionPeerError.unavailable }
        return try await SurfaceCommandService.execute(
            providerID: "colorPicker", command: command, payload: payload,
            snapshot: { tile in
                try await ColorPickerSurface.snapshot(
                    tile: tile, clipboardActive: ColorPickerClipboardPeer.active,
                    pinToTop: ColorPickerClipboardPeer.pinToTop,
                    entries: { try await ColorPickerClipboardPeer.entries() })
            },
            perform: { action in
                if action == "pick" {
                    store.pick()
                } else {
                    try await ColorPickerClipboardPeer.perform(action)
                }
            })
    }

    func configureUI(_ configuration: ExtensionUIConfiguration) -> Bool {
        guard !suspended, !environmentFixtureActive,
            configuration.input["hostedFunctionalFixture"] == nil, uiDrains.count < 8,
            configuration.defaultsSuite
                == ExtensionEnvironment.values["EDITH_SHARED_DEFAULTS_SUITE"]
        else { return false }
        _ = retirePresentation()
        presentation = ControlPresentation(client: configuration.engineClient)
        return true
    }

    func view(for presentation: UUID, context: ExtensionHostContext) -> NSViewController? {
        guard !suspended, !environmentFixtureActive, !context.isHostedFunctionalFixture,
            let presentation = self.presentation
        else { return nil }
        return NSHostingController(
            rootView: ExtensionPageHost {
                ControlSettingsHost(presentation: presentation) {
                    Form { ColorPickerRows(presentation: presentation) }.settingsForm()
                }
            })
    }

    func stopUI() -> [Task<Void, Never>] {
        retirePresentation().map { [$0] } ?? []
    }

    func cancelPendingWork() {
        suspended = true
        presentation?.stop()
        store?.shutdown()
    }

    func drain() async {
        await store?.stopAndWait()
        await presentation?.stopAndWait()
        await finishRetiredPresentations()
    }

    func teardown() async {
        let owner = store
        store = nil
        _ = retirePresentation()
        IPC.stopObserving(observer)
        observer = nil
        await finishRetiredPresentations()
        owner?.shutdown()
        HotKeyRegistrar.shutdown()
    }

    private func retirePresentation() -> Task<Void, Never>? {
        guard let owner = presentation else { return nil }
        owner.stop()
        let id = UUID()
        let task = Task { [self, owner] in
            defer { uiDrains[id] = nil }
            await owner.stopAndWait()
        }
        uiDrains[id] = task
        presentation = nil
        return task
    }

    private func finishRetiredPresentations() async {
        while let task = uiDrains.values.first { await task.value }
    }
}

@MainActor
func makeColorPickerRuntime() -> ExtensionServiceRuntime {
    final class BundleAnchor {}
    return ExtensionServiceRuntime(
        id: "colorPicker", role: "helper", bundle: Bundle(for: BundleAnchor.self)
    ) { ColorPickerService(runtime: $0) }
}

@_cdecl("edith_extension_create")
public func createExtension() -> UnsafeMutableRawPointer? {
    UnsafeMutableRawPointer(
        bitPattern: MainActor.assumeIsolated {
            UInt(bitPattern: Unmanaged.passRetained(makeColorPickerRuntime()).toOpaque())
        })
}
