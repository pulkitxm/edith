#if canImport(WorkerFixtureSupport)
import WorkerFixtureSupport
#endif
import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import SwiftUI

@MainActor
final class KeepAwakeService: ExtensionService {
    typealias FixtureAuthority = WorkerFixtureAdmission
    private unowned let runtime: ExtensionServiceRuntime
    private var store: KeepAwakeStore?
    private var defaults: UserDefaults?
    private var defaultsSuite: String?
    private let admitFixture: (NSDictionary) throws -> FixtureAuthority?
    private let makeDefaults: (String) -> UserDefaults?
    private let makeProductionStore: @MainActor (UserDefaults) -> KeepAwakeStore
    private var presentation: ControlPresentation?
    private var presentationDrains: [UUID: Task<Void, Never>] = [:]

    init(
        runtime: ExtensionServiceRuntime,
        admitFixture: ((NSDictionary) throws -> FixtureAuthority?)? = nil,
        makeDefaults: @escaping (String) -> UserDefaults? = { UserDefaults(suiteName: $0) },
        makeProductionStore: @escaping @MainActor (UserDefaults) -> KeepAwakeStore = {
            KeepAwakeStore(defaults: $0)
        }
    ) {
        self.runtime = runtime
        self.admitFixture = admitFixture ?? Self.admitFixtureContext
        self.makeDefaults = makeDefaults
        self.makeProductionStore = makeProductionStore
    }

    var isRunning: Bool { store != nil }
    var preventingSleep: Bool { store?.preventingSleep ?? false }
    var preparesForDisable: Bool { true }
    var allowsUIDuringRetirement: Bool { true }
    var statusDetails: [String: Any] {
        ["preventingSleep": !runtime.isStopping && preventingSleep]
    }

    private static func fixtureActive(_ input: NSDictionary) -> Bool {
        ExtensionEnvironment.values["EDITH_FUNCTIONAL_FIXTURE"] != nil
            || input["hostedFunctionalFixture"] != nil
    }

    private static func admitFixtureContext(_ input: NSDictionary) throws -> FixtureAuthority? {
        guard ExtensionEnvironment.values["EDITH_FUNCTIONAL_FIXTURE"] == nil,
            input["hostedFunctionalFixture"] == nil
        else { throw WorkerFixtureError.invalid }
        return try WorkerFixtureAdmission.current(
            extensionID: "keepAwake", context: input, roleBundle: Bundle(for: KeepAwakeService.self)
        )
    }

    func start(_ context: ExtensionHostContext) -> Bool {
        guard !Self.fixtureActive(context.input), !ExtensionHostRole.isInterfaceProcess,
            presentation == nil
        else { return false }
        let input = context.input
        do {
            let verified = try admitFixture(input)
            guard let suite = input["defaultsSuite"] as? String,
                defaultsSuite == nil || defaultsSuite == suite
            else { return false }
            if input["recoveryOnly"] as? Bool == true {
                defaults = makeDefaults(suite)
                defaultsSuite = suite
                return true
            }
            guard let values = makeDefaults(suite) else {
                throw ExtensionPeerError.unavailable
            }
            let owner =
                store
                ?? (verified == nil
                    ? makeProductionStore(values)
                    : KeepAwakeStore.fixture(defaults: values))
            values.set(true, forKey: KeepAwakeKeys.enabled)
            owner.syncPreventSleep()
            store = owner
            defaults = values
            defaultsSuite = suite
            return true
        } catch { return false }
    }

    func synchronize(_ context: ExtensionHostContext) -> Bool {
        guard !(runtime.isSuspended || runtime.isStopping), !Self.fixtureActive(context.input)
        else { return false }
        store?.syncPreventSleep()
        return true
    }

    func invoke(_ command: String, payload: Data) async throws -> Data {
        guard ExtensionEnvironment.values["EDITH_FUNCTIONAL_FIXTURE"] == nil else {
            throw ExtensionPeerError.rejected("The functional fixture is unavailable.")
        }
        try Task.checkCancellation()
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

    func configureUI(_ configuration: ExtensionUIConfiguration) -> Bool {
        guard !Self.fixtureActive(configuration.input), presentationDrains.count < 8,
            configuration.defaultsSuite
                == ExtensionEnvironment.values["EDITH_SHARED_DEFAULTS_SUITE"]
        else { return false }
        _ = stopPresentation()
        presentation = ControlPresentation(client: configuration.engineClient)
        return true
    }

    func view(for presentationID: UUID, context: ExtensionHostContext) -> NSViewController? {
        guard !(runtime.isSuspended || runtime.isStopping), !Self.fixtureActive(context.input),
            let presentation
        else { return nil }
        return NSHostingController(
            rootView: ExtensionPageHost {
                ControlSettingsHost(presentation: presentation) {
                    KeepAwakeSettings(
                        defaults: SharedDefaults.store, synchronize: { presentation.changed() })
                }
            })
    }

    func stopUI(for presentationID: UUID?) -> [Task<Void, Never>] {
        stopPresentation().map { [$0] } ?? []
    }

    func cancelPendingWork() {
        store?.cancelPendingCommands()
        presentation?.stop()
    }

    func drain() async {
        await presentation?.stopAndWait()
        while let task = presentationDrains.values.first { await task.value }
    }

    func prepareDisable() async throws {
        defaults?.set(false, forKey: AppStorageKeys.General.preventSleep)
    }

    func teardown() async {
        let owner = store
        let stopping = stopPresentation()
        store = nil
        defaults = nil
        defaultsSuite = nil
        await stopping?.value
        owner?.shutdown()
    }

    func perform(_ operation: String, context: NSDictionary) -> NSObject? {
        operation == "prepareToStop" ? runtime.execute(["operation": "stop"]) : nil
    }

    private func stopPresentation() -> Task<Void, Never>? {
        let owner = presentation
        presentation = nil
        owner?.stop()
        guard let owner else { return nil }
        let id = UUID()
        let task = Task { [self] in
            defer { presentationDrains[id] = nil }
            await owner.stopAndWait()
        }
        presentationDrains[id] = task
        return task
    }
}

@MainActor
func makeKeepAwakeRuntime() -> ExtensionServiceRuntime {
    final class BundleAnchor {}
    return ExtensionServiceRuntime(
        id: "keepAwake", role: "helper", bundle: Bundle(for: BundleAnchor.self)
    ) { KeepAwakeService(runtime: $0) }
}

#if !SWIFT_PACKAGE
@_cdecl("edith_extension_create")
public func createKeepAwakeExtension() -> UnsafeMutableRawPointer? {
    let address = MainActor.assumeIsolated {
        UInt(bitPattern: Unmanaged.passRetained(makeKeepAwakeRuntime()).toOpaque())
    }
    return UnsafeMutableRawPointer(bitPattern: address)
}
#endif
