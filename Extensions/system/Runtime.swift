import AppKit
import EdithExtensionCommands
import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import SwiftUI

@MainActor
final class SystemService: ExtensionService {
    private var model: RunningAppsModel?
    private var uiModel: RunningAppsModel?
    private var uiPresentation: SystemPresentationState?
    private var uiClient: ExtensionEngineClient?
    private var uiSettings = false
    private var presentation: SystemPresentationState?
    private var cleaning: KeyboardCleaning?
    private let operations: RunningAppOperationCenter = {
        guard ExtensionEnvironment.values["EDITH_EXTENSION_FIXTURE_HOME"] != nil else {
            return RunningAppOperationCenter()
        }
        return RunningAppOperationCenter(
            snapshot: {
                [
                    .init(
                        pid: 12345, name: "Synthetic editor", bundleID: "test.synthetic.editor",
                        active: true)
                ]
            }, perform: { _, _ in 0 },
            resource: { _ in .init(cpuNanoseconds: 0, memoryMB: 0) })
    }()

    var isRunning: Bool { model != nil }
    var allowsUIDuringRetirement: Bool { true }

    func start() -> Bool {
        if model == nil { model = RunningAppsModel(operations: operations) }
        if presentation == nil { presentation = SystemPresentationState() }
        if cleaning == nil { cleaning = KeyboardCleaning() }
        return true
    }

    func synchronize() {
        let defaults = SharedDefaults.store
        if let raw = defaults.string(forKey: RunningAppsKeys.sort),
            AppSortKey(rawValue: raw) != nil
        {
            model?.restoreSort(
                SystemAppsSort(
                    sortKey: raw, ascending: defaults.bool(forKey: RunningAppsKeys.ascending)))
        }
    }

    func invoke(_ command: String, payload: Data) async throws -> Data {
        guard model != nil else { throw ExtensionPeerError.unavailable }
        if command == "surface.snapshot" || command == "surface.perform" {
            return try await SurfaceCommandService.execute(
                providerID: "system", command: command, payload: payload,
                snapshot: { tile in
                    SystemSurface.snapshot(
                        apps: self.operations.list(), tile: tile,
                        cleaning: self.cleaning?.status)
                },
                perform: { action in
                    if action == "cleanKeys" || action == "stopCleaning" {
                        guard let cleaning = self.cleaning else {
                            throw ExtensionPeerError.unavailable
                        }
                        _ = try cleaning.execute("system." + action, payload: Data())
                        return
                    }
                    throw ExtensionPeerError.invalidRequest
                })
        }
        if command == "system.cli.catalog" { return try SystemCLICatalog.data() }
        switch command {
        case "system.cli":
            let request = try JSONDecoder().decode(ExtensionCLIRequest.self, from: payload)
            return try JSONEncoder().encode(
                try await SystemCLIExecution.run(request, operations: operations))
        case "system.apps.snapshot":
            guard payload == Data("{}".utf8), let model = model,
                let presentation = presentation
            else { throw ExtensionPeerError.invalidRequest }
            await model.refresh()
            return try JSONEncoder().encode(model.snapshot(presentation: presentation))
        case "system.presentation":
            let wait = try JSONDecoder().decode(SystemPresentationWait.self, from: payload)
            guard let presentation = presentation else {
                throw ExtensionPeerError.invalidRequest
            }
            let hideApps = await presentation.waitForChange(
                from: wait.hideApps, timeout: .seconds(10))
            return try JSONEncoder().encode(SystemPresentationReply(hideApps: hideApps))
        case "system.apps.sort":
            let sort = try JSONDecoder().decode(SystemAppsSort.self, from: payload)
            guard let key = AppSortKey(rawValue: sort.sortKey) else {
                throw ExtensionPeerError.invalidRequest
            }
            SharedDefaults.store.set(key.rawValue, forKey: RunningAppsKeys.sort)
            SharedDefaults.store.set(sort.ascending, forKey: RunningAppsKeys.ascending)
            model?.restoreSort(sort)
            return Data("{}".utf8)
        case "system.cleanKeys", "system.stopCleaning", "system.cleaning.status":
            guard let cleaning = self.cleaning else { throw ExtensionPeerError.unavailable }
            return try cleaning.execute(command, payload: payload)
        case "apps.list":
            return try JSONSerialization.data(
                withJSONObject: operations.list().map(Self.encode))
        case "apps.quit":
            let request = try SystemAppsQuitRequest.decode(payload)
            let plan = try operations.plan(try request.selection(), force: request.force)
            let outcome = operations.apply(plan, confirmed: request.confirmed)
            return try JSONSerialization.data(withJSONObject: [
                "applied": outcome.applied, "changed": outcome.changed,
                "targets": plan.targets.map(Self.encode),
            ])
        default: throw ExtensionPeerError.rejected("System does not support this command.")
        }
    }

    func configureUI(_ configuration: ExtensionUIConfiguration) -> Bool {
        guard let client = configuration.engineClient,
            let defaults = UserDefaults(suiteName: configuration.defaultsSuite)
        else { return false }
        releaseUI()
        let presentation = SystemPresentationState(channel: nil)
        uiClient = client
        uiSettings = configuration.isSettings
        uiPresentation = presentation
        uiModel = RunningAppsModel(
            engineClient: client, presentation: presentation, defaults: defaults)
        return true
    }

    func view(for presentation: UUID) -> NSViewController? {
        guard let model = uiModel, let presentation = uiPresentation else { return nil }
        if uiSettings, let client = uiClient {
            return NSHostingController(
                rootView: ExtensionPageHost {
                    SystemSettings { _ = try? await client.invoke("system.cleanKeys") }
                })
        }
        return NSHostingController(
            rootView: ExtensionPageHost { SystemPage(model: model, presentation: presentation) })
    }

    func stopUI() -> [Task<Void, Never>] {
        releaseUI()
        return []
    }

    func cancelPendingWork() {
        cleaning?.shutdown()
        model?.beginSuspension()
        uiModel?.beginSuspension()
    }

    func drain() async {
        await cleaning?.shutdownAndWait()
        await model?.suspendAndWait()
        await uiModel?.suspendAndWait()
    }

    func teardown() async {
        releaseUI()
        cleaning?.shutdown()
        cleaning = nil
        model?.shutdown()
        model = nil
        presentation?.shutdown()
        presentation = nil
    }

    private func releaseUI() {
        uiSettings = false
        uiModel?.shutdown()
        uiModel = nil
        uiPresentation?.shutdown()
        uiPresentation = nil
        uiClient?.invalidate()
        uiClient = nil
    }

    private static func encode(_ snapshot: RunningAppSnapshot) -> [String: Any] {
        [
            "pid": snapshot.pid, "name": snapshot.name, "bundleID": snapshot.bundleID ?? "",
            "active": snapshot.active, "cpuPercent": snapshot.cpuPercent,
            "memoryMB": snapshot.memoryMB,
        ]
    }
}

@MainActor
func makeSystemRuntime() -> ExtensionServiceRuntime {
    final class BundleAnchor {}
    return ExtensionServiceRuntime(
        id: "system", role: "app", bundle: Bundle(for: BundleAnchor.self)
    ) { _ in SystemService() }
}

@_cdecl("edith_extension_create")
public func createExtension() -> UnsafeMutableRawPointer? {
    UnsafeMutableRawPointer(
        bitPattern: MainActor.assumeIsolated {
            UInt(bitPattern: Unmanaged.passRetained(makeSystemRuntime()).toOpaque())
        })
}
