import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import SwiftUI
#if canImport(WorkerFixtureSupport)
import WorkerFixtureSupport
#endif

@MainActor
@objc(EdithBlitzTreeExtensionRuntime)
final class ExtensionRuntime: NSObject {
    private var model: BlitzTreeModel?
    private var uiModel: BlitzTreeModel?
    private var uiClient: ExtensionEngineClient?
    private var commandDrain: Task<Void, Never>?
    private var resourceStop: Task<Void, Never>?
    private var commandsSuspended = false
    private var uiDrains: [UUID: Task<Void, Never>] = [:]
    private let commands = ExtensionCommandRegistry()
    #if EDITH_FUNCTIONAL_FIXTURE
    private var fixture: WorkerFixtureEngineAdmission?
    private var fixtureFiles: BlitzTreeFixtureFiles?
    private var fixtureUI: WorkerFixtureUIAdmission?
    #endif

    @objc func invoke(_ request: NSDictionary, completion: @escaping (NSData?, NSString?) -> Void) {
        #if EDITH_FUNCTIONAL_FIXTURE
        let token = (request["token"] as? String).flatMap(UUID.init(uuidString:))
        #endif
        commands.invoke(request, completion: completion) { [weak self] command, payload in
            guard let self, let model = self.model else { throw ExtensionPeerError.unavailable }
            #if EDITH_FUNCTIONAL_FIXTURE
            if let fixture, let fixtureFiles {
                guard let token else { throw WorkerFixtureError.invalid }
                return try await fixtureFiles.withAction {
                    try fixtureFiles.validateCommand(command, payload: payload)
                    let pending = try fixture.beginRequest(
                        token: token, operation: command, payload: payload)
                    do {
                        _ = try await BlitzTreeCommands.execute(
                            command, payload: payload, model: model)
                        await model.finishWork()
                        if command == "blitztree.ui.trash" { await model.finishWork() }
                        try Task.checkCancellation()
                        if let error = model.error { throw ExtensionPeerError.rejected(error) }
                        let result = try JSONEncoder().encode(model.uiSnapshot())
                        try fixture.completeRequest(pending)
                        return result
                    } catch {
                        await model.finishWork()
                        fixture.cancelRequest(pending)
                        throw error
                    }
                }
            }
            #endif
            if command == "surface.snapshot" || command == "surface.perform" {
                return try await SurfaceCommandService.execute(
                    providerID: "blitztree", command: command, payload: payload,
                    snapshot: { tile in BlitzTreeSurface.snapshot(model) },
                    perform: { action in
                        switch action {
                        case "choose": model.chooseFolder()
                        case "rescan":
                            guard let root = model.root else {
                                throw ExtensionPeerError.invalidRequest
                            }; model.scan(root, remember: false)
                        case "cancel": model.cancel()
                        default: throw ExtensionPeerError.invalidRequest
                        }
                    })
            }
            return try await BlitzTreeCommands.execute(command, payload: payload, model: model)
        }
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
        let owner = model
        let uiOwner = uiModel
        commandsSuspended = true
        #if EDITH_FUNCTIONAL_FIXTURE
        let fixture = fixture
        let files = fixtureFiles
        fixture?.closeNamespaceAdmission()
        files?.closeAdmission()
        #endif
        _ = commands.suspend()
        if let commandDrain { return commandDrain }
        owner?.cancelPendingCommands()
        uiOwner?.cancelPendingCommands()
        if let commandDrain { return commandDrain }
        let task = Task { [self] in
            _ = await commands.suspendAndWait()
            await owner?.cancelAndWait()
            await uiOwner?.cancelAndWait()
            while let task = uiDrains.values.first { await task.value }
            #if EDITH_FUNCTIONAL_FIXTURE
            await files?.closeAndWait()
            await fixture?.waitForNamespaceCallbacks()
            #endif
        }
        commandDrain = task
        return task
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
        let owner = model
        let drain = beginCommandDrain()
        if let resourceStop { return resourceStop }
        stopUI()
        model = nil
        let task = Task { [self] in
            await drain.value
            await commands.shutdownAndWait()
            await owner?.shutdown()
            #if EDITH_FUNCTIONAL_FIXTURE
            fixtureFiles = nil; fixture = nil
            #endif
        }
        resourceStop = task
        return task
    }

    @objc func execute(_ input: NSDictionary) -> NSObject {
        switch input["operation"] as? String {
        case "describe":
            let bundle = Bundle(for: ExtensionRuntime.self)
            return [
                "id": "blitztree", "role": "app",
                "version": bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                    as? String ?? "",
                "hostABI": bundle.object(forInfoDictionaryKey: "EdithHostABI") as? String ?? "",
            ] as NSDictionary
        case "start":
            guard !commandsSuspended else { return ["ok": false] as NSDictionary }
            guard let suite = input["defaultsSuite"] as? String,
                suite == ProcessInfo.processInfo.environment["EDITH_SHARED_DEFAULTS_SUITE"]
            else { return ["ok": false] as NSDictionary }
            #if EDITH_FUNCTIONAL_FIXTURE
            do {
                let admitted = try WorkerFixtureEngineAdmission.current(
                    extensionID: "blitztree", context: input,
                    roleBundle: Bundle(for: ExtensionRuntime.self), expectedRole: .app)
                if let fixture {
                    guard let admitted, admitted.descriptor == fixture.descriptor else {
                        throw WorkerFixtureError.invalid
                    }
                    try fixture.requireCurrent()
                } else if let admitted {
                    guard model == nil else { throw WorkerFixtureError.invalid }
                    let files = try BlitzTreeFixtureFiles(admitted)
                    model = BlitzTreeModel(
                        client: BlitzTreeClient { root, progress in
                            try await files.scan(root, progress: progress)
                        },
                        remove: { entry, root, cancellation in
                            try await files.trash(entry, root: root, cancellation: cancellation)
                        })
                    fixtureFiles = files; fixture = admitted
                }
            } catch { return ["ok": false] as NSDictionary }
            #else
            guard !Self.hasFixtureIntent(input) else { return ["ok": false] as NSDictionary }
            #endif
            if model == nil { model = BlitzTreeModel() }
        case "configureUI":
            guard !commandsSuspended, uiDrains.count < 8 else {
                return ["ok": false] as NSDictionary
            }
            guard let configuration = ExtensionUIConfiguration(context: input),
                let client = configuration.engineClient
            else { return ["ok": false] as NSDictionary }
            #if EDITH_FUNCTIONAL_FIXTURE
            let admission: WorkerFixtureUIAdmission?
            do {
                admission = try WorkerFixtureUIAdmission.current(
                    extensionID: "blitztree", context: input,
                    roleBundle: Bundle(for: ExtensionRuntime.self))
                try admission?.requireCurrent()
            } catch { return ["ok": false] as NSDictionary }
            #else
            guard !Self.hasFixtureIntent(input) else { return ["ok": false] as NSDictionary }
            #endif
            stopUI(); uiClient = client; uiModel = BlitzTreeModel(engineClient: client)
            #if EDITH_FUNCTIONAL_FIXTURE
            fixtureUI = admission
            #endif
            TextEditingCommands.install()
        case "stopUI": stopUI()
        case "view":
            guard !commandsSuspended else { return ["ok": false] as NSDictionary }
            guard let model = uiModel else { return ["ok": false] as NSDictionary }
            #if EDITH_FUNCTIONAL_FIXTURE
            do { try fixtureUI?.requireCurrent() } catch { return ["ok": false] as NSDictionary }
            #endif
            return NSHostingController(
                rootView: ExtensionPageHost { BlitzTreePage(model: model) })
        case "cancelCommand": commands.cancel(input["token"] as? String ?? "")
        case "synchronize": break
        case "stop":
            _ = beginResourceStop()
        case "status": return ["ok": true, "running": model != nil] as NSDictionary
        default: return ["ok": false] as NSDictionary
        }
        return ["ok": true] as NSDictionary
    }

    private static func hasFixtureIntent(_ input: NSDictionary) -> Bool {
        let environment = ProcessInfo.processInfo.environment
        return input["hostedFunctionalFixture"] != nil
            || environment["EDITH_FUNCTIONAL_FIXTURE"] != nil
            || environment["EDITH_EXTENSION_FIXTURE_HOME"] != nil
            || (input["hostIdentifier"] as? String)?.hasPrefix("com.pulkit.edith.tests.") == true
            || environment["EDITH_APPLICATION_IDENTIFIER"]?.hasPrefix("com.pulkit.edith.tests.")
                == true
            || environment["EDITH_SHARED_DEFAULTS_SUITE"]?.hasPrefix("com.pulkit.edith.tests.")
                == true
    }

    private func stopUI() {
        TextEditingCommands.shutdown()
        let model = uiModel; uiModel = nil
        #if EDITH_FUNCTIONAL_FIXTURE
        let admission = fixtureUI; fixtureUI = nil
        #endif
        uiClient?.invalidate(); uiClient = nil
        model?.cancelPendingCommands()
        let id = UUID()
        uiDrains[id] = Task { [self] in
            defer { uiDrains[id] = nil }
            await model?.shutdown()
            #if EDITH_FUNCTIONAL_FIXTURE
            withExtendedLifetime(admission) {}
            #endif
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
