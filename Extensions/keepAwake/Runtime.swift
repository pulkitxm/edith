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
    typealias FixtureAuthority = WorkerFixtureAdmission
    private var store: KeepAwakeStore?
    private var defaults: UserDefaults?
    private var defaultsSuite: String?
    private let admitFixture: (NSDictionary) throws -> FixtureAuthority?
    private let makeDefaults: (String) -> UserDefaults?
    private let makeProductionStore: @MainActor (UserDefaults) -> KeepAwakeStore

    override convenience init() { self.init(admitFixture: Self.admitFixtureContext) }

    init(
        admitFixture: @escaping (NSDictionary) throws -> FixtureAuthority?,
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
    private var resourceStop: Task<Void, Never>?
    private var commandsSuspended = false
    private var presentationDrains: [UUID: Task<Void, Never>] = [:]
    private let commands = ExtensionCommandRegistry()

    @objc func invoke(_ request: NSDictionary, completion: @escaping (NSData?, NSString?) -> Void) {
        guard ExtensionEnvironment.values["EDITH_FUNCTIONAL_FIXTURE"] == nil,
            request["hostedFunctionalFixture"] == nil
        else { completion(nil, "The functional fixture is unavailable."); return }
        let token = (request["token"] as? String).flatMap(UUID.init(uuidString:))
        commands.invoke(request, completion: completion) { [weak self] command, payload in
            guard let self, let token else { throw ExtensionPeerError.invalidRequest }
            try Task.checkCancellation()
            return try await self.executeCommand(command, payload: payload)
        }
    }

    private static func admitFixtureContext(_ input: NSDictionary) throws -> FixtureAuthority? {
        guard ExtensionEnvironment.values["EDITH_FUNCTIONAL_FIXTURE"] == nil,
            input["hostedFunctionalFixture"] == nil
        else { throw WorkerFixtureError.invalid }
        return try WorkerFixtureAdmission.current(
            extensionID: "keepAwake", context: input, roleBundle: Bundle(for: KeepAwakeRuntime.self)
        )
    }

    private func checkFixtureCurrent() throws {
        guard ExtensionEnvironment.values["EDITH_FUNCTIONAL_FIXTURE"] == nil else {
            throw WorkerFixtureError.invalid
        }
    }

    private func executeCommand(_ command: String, payload: Data) async throws -> Data {
        if command.hasPrefix("keepAwake.ui.") {
            guard self.store != nil else { throw ExtensionPeerError.unavailable }
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
        guard let store = self.store, let defaults = self.defaults else {
            throw ExtensionPeerError.unavailable
        }
        return try await KeepAwakeSurface.execute(
            command, payload: payload, store: store, defaults: defaults)
    }

    @objc(suspendCommandsWithCompletion:)
    func suspendCommands(completion: @escaping () -> Void) {
        let drain = beginCommandDrain()
        Task { [self] in
            await drain.value
            await resourceStop?.value
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
        if let commandDrain { return commandDrain }
        let task = Task { [self] in
            _ = await commands.suspendAndWait()
            await uiOwner?.stopAndWait()
            while let task = presentationDrains.values.first { await task.value }
            withExtendedLifetime(owner) {}
        }
        commandDrain = task
        return task
    }

    @objc(prepareDisableWithCompletion:)
    func prepareDisable(completion: @escaping (NSError?) -> Void) {
        let values = defaults
        let drain = beginCommandDrain()
        Task { [self] in
            await drain.value
            values?.set(false, forKey: AppStorageKeys.General.preventSleep)
            withExtendedLifetime(self) { completion(nil) }
        }
    }

    @objc(prepareToStopWithCompletion:)
    func prepareToStop(completion: @escaping () -> Void) {
        let stop = beginResourceStop()
        Task { [self] in
            await stop.value
            withExtendedLifetime(self) { completion() }
        }
    }

    private func beginResourceStop() -> Task<Void, Never> {
        if let resourceStop { return resourceStop }
        let owner = store
        let drain = beginCommandDrain()
        if let resourceStop { return resourceStop }
        stopPresentation()
        store = nil; defaults = nil; defaultsSuite = nil
        let task = Task { [self] in
            await drain.value
            await commands.shutdownAndWait()
            owner?.shutdown()
        }
        resourceStop = task
        return task
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
        if ExtensionEnvironment.values["EDITH_FUNCTIONAL_FIXTURE"] != nil
            || input["hostedFunctionalFixture"] != nil
        {
            let allowed = [
                "describe", "status", "stop", "stopUI", "prepareToStop", "cancelCommand",
            ]
            guard let operation = input["operation"] as? String, allowed.contains(operation) else {
                return ["ok": false] as NSDictionary
            }
        }
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
                    == ExtensionEnvironment.values["EDITH_SHARED_DEFAULTS_SUITE"]
            else { return ["ok": false] as NSDictionary }
            stopPresentation()
            presentation = ControlPresentation(client: configuration.engineClient)
            return ["ok": true] as NSDictionary
        case "stopUI":
            stopPresentation()
            return ["ok": true] as NSDictionary
        case "prepareToStop":
            _ = beginResourceStop()
            return ["ok": true] as NSDictionary
        case "start":
            guard !commandsSuspended else { return ["ok": false] as NSDictionary }
            guard !ExtensionHostRole.isInterfaceProcess, presentation == nil
            else { return ["ok": false] as NSDictionary }
            do {
                let verified = try admitFixture(input)
                guard let suite = input["defaultsSuite"] as? String,
                    defaultsSuite == nil || defaultsSuite == suite
                else { return ["ok": false] as NSDictionary }
                if input["recoveryOnly"] as? Bool == true {
                    defaults = makeDefaults(suite)
                    defaultsSuite = suite
                    return ["ok": true] as NSDictionary
                }
                let admission = verified
                let construct: (WorkerFixtureAdmission?) throws -> (UserDefaults, KeepAwakeStore) =
                    { [self] namespace in
                        guard let values = makeDefaults(suite) else {
                            throw ExtensionPeerError.unavailable
                        }
                        let owner =
                            store
                            ?? (namespace == nil
                                ? makeProductionStore(values)
                                : KeepAwakeStore.fixture(defaults: values))
                        values.set(true, forKey: KeepAwakeKeys.enabled)
                        owner.syncPreventSleep()
                        return (values, owner)
                    }
                let (values, owner): (UserDefaults, KeepAwakeStore)
                (values, owner) = try construct(admission)
                store = owner
                defaults = values
                defaultsSuite = suite
                return ["ok": true] as NSDictionary
            } catch { return ["ok": false] as NSDictionary }
        case "view":
            guard !commandsSuspended else { return ["ok": false] as NSDictionary }
            guard let presentation else { return ["ok": false] as NSDictionary }
            return NSHostingController(
                rootView: ExtensionPageHost {
                    ControlSettingsHost(presentation: presentation) {
                        KeepAwakeSettings(
                            defaults: SharedDefaults.store, synchronize: { presentation.changed() })
                    }
                })
        case "synchronize":
            guard !commandsSuspended else { return ["ok": false] as NSDictionary }
            do {
                try checkFixtureCurrent()
                store?.syncPreventSleep()
                return ["ok": true] as NSDictionary
            } catch { return ["ok": false] as NSDictionary }
        case "cancelCommand":
            commands.cancel(input["token"] as? String ?? "")
            return ["ok": true] as NSDictionary
        case "stop":
            _ = beginResourceStop()
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
