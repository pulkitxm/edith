#if canImport(WorkerFixtureSupport)
import WorkerFixtureSupport
#endif
import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import SwiftUI

@MainActor
@objc(EdithKeepAwakeExtensionRuntime)
final class KeepAwakeRuntime: NSObject {
    private var store: KeepAwakeStore?
    private var defaults: UserDefaults?
    private var defaultsSuite: String?
    private let admitFixture: (NSDictionary) throws -> WorkerFixtureAdmission?
    private let makeDefaults: (String) -> UserDefaults?
    private let makeProductionStore: @MainActor (UserDefaults) -> KeepAwakeStore

    override convenience init() {
        self.init(admitFixture: {
            try WorkerFixtureAdmission.current(
                extensionID: "keepAwake", context: $0,
                roleBundle: Bundle(for: KeepAwakeRuntime.self))
        })
    }

    init(
        admitFixture: @escaping (NSDictionary) throws -> WorkerFixtureAdmission?,
        makeDefaults: @escaping (String) -> UserDefaults? = { UserDefaults(suiteName: $0) },
        makeProductionStore: @escaping @MainActor (UserDefaults) -> KeepAwakeStore = {
            KeepAwakeStore(defaults: $0)
        }
    ) {
        self.admitFixture = admitFixture
        self.makeDefaults = makeDefaults
        self.makeProductionStore = makeProductionStore
        super.init()
    }

    private var presentation: ControlPresentation?

    private var commandDrain: Task<Void, Never>?
    private var commandsSuspended = false
    private var presentationDrains: [UUID: Task<Void, Never>] = [:]
    private let commands = ExtensionCommandRegistry()

    @objc func invoke(_ request: NSDictionary, completion: @escaping (NSData?, NSString?) -> Void) {
        commands.invoke(request, completion: completion) { [weak self] command, payload in
            if command.hasPrefix("keepAwake.ui.") {
                guard let self, self.store != nil else { throw ExtensionPeerError.unavailable }
                let defaults = self.defaults ?? SharedDefaults.store
                switch command {
                case "keepAwake.ui.read":
                    guard payload == Data("{}".utf8) else {
                        throw ExtensionPeerError.invalidRequest
                    }
                case "keepAwake.ui.update":
                    try ControlPresentationContract.update(payload, defaults: defaults)
                    self.store?.syncPreventSleep()
                case "keepAwake.ui.action":
                    _ = try JSONDecoder().decode(
                        ControlPresentationAction.self, from: payload)
                    throw ExtensionPeerError.invalidRequest
                default: throw ExtensionPeerError.invalidRequest
                }
                return try ControlPresentationContract.snapshot(
                    defaults: defaults, state: ControlPresentationState())
            }
            guard let self, let store = self.store, let defaults = self.defaults else {
                throw ExtensionPeerError.unavailable
            }
            return try await KeepAwakeSurface.execute(
                command, payload: payload, store: store, defaults: defaults)
        }
    }

    @objc(suspendCommandsWithCompletion:)
    func suspendCommands(completion: @escaping () -> Void) {
        let drain = beginCommandDrain()
        Task { [self] in
            await drain.value
            withExtendedLifetime(self) { completion() }
        }
    }

    private func beginCommandDrain() -> Task<Void, Never> {
        let owner = store
        let uiOwner = presentation
        commandsSuspended = true
        _ = commands.suspend()
        if let commandDrain { return commandDrain }
        owner?.cancelPendingCommands()
        uiOwner?.stop()
        let task = Task { [self] in
            _ = await commands.suspendAndWait()
            await uiOwner?.stopAndWait()
            while let task = presentationDrains.values.first { await task.value }
            withExtendedLifetime(owner) {}
        }
        commandDrain = task
        return task
    }

    @objc(prepareToStopWithCompletion:)
    func prepareToStop(completion: @escaping () -> Void) {
        let owner = store
        let drain = beginCommandDrain()
        Task { [self] in
            await drain.value
            await commands.shutdownAndWait()
            owner?.shutdown()
            _ = execute(["operation": "stop"])
            completion()
        }
    }

    private func stopPresentation() {
        let owner = presentation
        presentation = nil
        owner?.stop()
        guard let owner else { return }
        let id = UUID()
        presentationDrains[id] = Task { [self] in
            defer { presentationDrains[id] = nil }
            await owner.stopAndWait()
        }
    }

    @objc func execute(_ input: NSDictionary) -> NSObject {
        switch input["operation"] as? String {
        case "describe":
            return [
                "id": "keepAwake",
                "version": Bundle(for: KeepAwakeRuntime.self).object(
                    forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development",
                "hostABI": Bundle(for: KeepAwakeRuntime.self).object(
                    forInfoDictionaryKey: "EdithHostABI") as? String ?? "runtime-1",
                "role": "helper",
            ] as NSDictionary
        case "configureUI":
            guard !commandsSuspended, presentationDrains.count < 8 else {
                return ["ok": false] as NSDictionary
            }
            guard let configuration = ExtensionUIConfiguration(context: input),
                configuration.extensionID == "keepAwake",
                configuration.defaultsSuite
                    == ProcessInfo.processInfo.environment["EDITH_SHARED_DEFAULTS_SUITE"]
            else { return ["ok": false] as NSDictionary }
            stopPresentation()
            presentation = ControlPresentation(client: configuration.engineClient)
            return ["ok": true] as NSDictionary
        case "stopUI":
            stopPresentation()
            return ["ok": true] as NSDictionary
        case "prepareToStop":
            commands.shutdown()
            return ["ok": true] as NSDictionary
        case "start":
            guard !commandsSuspended else { return ["ok": false] as NSDictionary }
            guard Bundle.main.bundleURL.pathExtension != "appex", presentation == nil
            else { return ["ok": false] as NSDictionary }
            do {
                let fixture = try admitFixture(input)
                guard let suite = input["defaultsSuite"] as? String,
                    defaultsSuite == nil || defaultsSuite == suite,
                    let defaults = makeDefaults(suite)
                else { return ["ok": false] as NSDictionary }
                if store == nil {
                    store =
                        fixture == nil
                        ? makeProductionStore(defaults) : KeepAwakeStore.fixture(defaults: defaults)
                }
                self.defaults = defaults
                defaultsSuite = suite
                defaults.set(true, forKey: KeepAwakeKeys.enabled)
                store?.syncPreventSleep()
                return ["ok": true] as NSDictionary
            } catch { return ["ok": false] as NSDictionary }
        case "view":
            guard let presentation else { return ["ok": false] as NSDictionary }
            return NSHostingController(
                rootView: ExtensionPageHost {
                    ControlSettingsHost(presentation: presentation) {
                        KeepAwakeSettings(
                            defaults: SharedDefaults.store, synchronize: { presentation.changed() })
                    }
                })
        case "synchronize":
            store?.syncPreventSleep()
            return ["ok": true] as NSDictionary
        case "cancelCommand":
            commands.cancel(input["token"] as? String ?? "")
            return ["ok": true] as NSDictionary
        case "stop":
            stopPresentation()
            commands.shutdown()
            store?.shutdown()
            store = nil
            defaults = nil
            defaultsSuite = nil
            return ["ok": true] as NSDictionary
        case "status":
            return [
                "ok": true, "running": store != nil,
                "preventingSleep": store?.preventingSleep ?? false,
            ] as NSDictionary
        default:
            return ["ok": false] as NSDictionary
        }
    }
}

#if !SWIFT_PACKAGE
@_cdecl("edith_extension_create")
public func createKeepAwakeExtension() -> UnsafeMutableRawPointer? {
    let address = MainActor.assumeIsolated {
        UInt(bitPattern: Unmanaged.passRetained(KeepAwakeRuntime()).toOpaque())
    }
    return UnsafeMutableRawPointer(bitPattern: address)
}
#endif
