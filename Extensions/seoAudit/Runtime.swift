import AppKit
import EdithExtensionCommands
import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import SwiftUI

@MainActor
final class SEOAuditExtensionService: ExtensionService {
    private unowned let runtime: ExtensionServiceRuntime
    private var service: SEOAuditService?
    private var uiService: SEOAuditService?
    private var uiModel: SEOAuditModel?
    private let snapshotOwner = UUID()
    private var uiEngine: SEOAuditUIEngine?
    private var engineClient: ExtensionEngineClient?
    private var operations: SEOAuditCommands?
    private var surface: SEOAuditSurface?
    private var startup: Task<Void, Never>?
    private var cliStreams: ExtensionCLIStreams?
    private var suspension: Task<Void, Never>?
    private var fixture: Bool {
        ExtensionEnvironment.values["EDITH_EXTENSION_FIXTURE_HOME"] != nil
    }

    init(runtime: ExtensionServiceRuntime) { self.runtime = runtime }

    var isRunning: Bool { service != nil }

    func start() -> Bool {
        guard service == nil else { return true }
        let root = ExtensionData.root.appendingPathComponent("SEOAudit", isDirectory: true)
        let network = SEOAuditHTTPClient(restrictToLoopback: fixture)
        let lighthouse = fixture ? LighthouseAuditor(locate: { nil }) : LighthouseAuditor()
        let workflow = SEOAuditWorkflow(
            repository: SEOAuditRepository(root: root), network: network, lighthouse: lighthouse
        )
        let service = SEOAuditService(workflow: workflow)
        self.service = service
        SEOAuditWorkerOperations.service = service
        uiEngine = SEOAuditUIEngine(service: service)
        operations = SEOAuditCommands(service: service)
        surface = SEOAuditSurface(service: service)
        SEOSnapshotCache.shared.configure(root: root, network: network)
        startup = Task { await SEOAuditModel.shared.refreshProjects() }
        return true
    }

    func invoke(_ command: String, payload: Data) async throws -> Data {
        guard service != nil else { throw ExtensionPeerError.unavailable }
        await startup?.value
        try Task.checkCancellation()
        if command == "seoAudit.cli.catalog" {
            return try ExtensionCLICatalog.data(
                SEOCommand.self, owner: "seoAudit", payload: payload, streaming: true)
        }
        if command.hasPrefix("seoAudit.cli.") {
            guard let service else { throw ExtensionPeerError.unavailable }
            if cliStreams == nil {
                cliStreams = try ExtensionCLIStreams(owner: "seoAudit")
            }
            guard let streams = cliStreams else { throw ExtensionPeerError.unavailable }
            return try SEOCLIExecution.stream(
                streams, operation: command, payload: payload, service: service)
        }
        if command == "seoAudit.cli", let service {
            let request = try JSONDecoder().decode(ExtensionCLIRequest.self, from: payload)
            return try JSONEncoder().encode(
                try await SEOCLIExecution.run(request, service: service))
        }
        if command.hasPrefix("seoAudit.ui."), let engine = uiEngine {
            return try await engine.execute(command, payload: payload)
        }
        if command.hasPrefix("surface."), let surface {
            return try await surface.execute(command, payload: payload)
        }
        guard let operations else { throw ExtensionPeerError.unavailable }
        return try await operations.execute(command, payload: payload)
    }

    func configureUI(_ configuration: ExtensionUIConfiguration) -> Bool {
        guard engineClient == nil, let client = configuration.engineClient else { return false }
        engineClient = client
        let bridge = SEOAuditUIBridge(client: client)
        let service = SEOAuditService(remote: bridge)
        uiService = service
        let model = SEOAuditModel(service: service)
        uiModel = model
        SEOAuditModel.shared = model
        SEOSnapshotCache.shared.configureRemote(owner: snapshotOwner) {
            try await bridge.call("image", url: $0, as: Data?.self)
        }
        return true
    }

    func view(for presentation: UUID) -> NSViewController? {
        guard uiService != nil, let model = uiModel else { return nil }
        let automatic = !fixture
        return NSHostingController(
            rootView: ExtensionPageHost {
                SEOAuditPage(model: model).environment(\.automaticViewActionsEnabled, automatic)
            })
    }

    func stopUI() -> [Task<Void, Never>] {
        let client = engineClient
        engineClient = nil
        let service = uiService
        let model = uiModel
        uiModel = nil
        SEOSnapshotCache.shared.releaseRemote(snapshotOwner)
        service?.beginSuspension()
        model?.shutdown()
        ExtensionUIResources.cleanup(of: runtime, key: "seoSnapshots") {
            SEOSnapshotCache.shared.shutdown()
        }
        uiService = nil
        guard service != nil else {
            client?.invalidate()
            return []
        }
        return [
            Task {
                defer { client?.invalidate() }
                await service?.shutdown()
                await model?.drain()
            }
        ]
    }

    func cancelPendingWork() {
        let service = service
        let uiService = uiService
        let startup = startup
        let streams = cliStreams
        let model = SEOAuditModel.shared
        let engine = uiEngine
        engine?.shutdown()
        startup?.cancel()
        streams?.stop()
        service?.beginSuspension()
        uiService?.beginSuspension()
        model.shutdown()
        suspension = Task {
            await startup?.value
            await streams?.stopAndWait()
            await service?.suspendAndWait()
            await uiService?.suspendAndWait()
            await model.suspendAndWait()
            await engine?.suspendAndWait()
        }
    }

    func drain() async {
        await suspension?.value
    }

    func teardown() async {
        let uiStops = stopUI()
        let streams = cliStreams
        cliStreams = nil
        streams?.stop()
        startup?.cancel()
        let engine = uiEngine
        engine?.shutdown()
        uiEngine = nil
        SEOAuditModel.shared.shutdown()
        SEOAuditPrivacyState.shared.shutdown()
        SEOSnapshotCache.shared.shutdown()
        SEOAuditWorkerOperations.service = nil
        operations?.shutdown()
        operations = nil
        surface = nil
        let service = service
        self.service = nil
        service?.beginSuspension()
        let model = SEOAuditModel.shared
        let startup = startup
        self.startup = nil
        await service?.shutdown()
        await startup?.value
        await model.drain()
        await engine?.shutdownAndWait()
        await streams?.stopAndWait()
        for task in uiStops { await task.value }
    }
}

@MainActor
func makeSEOAuditRuntime() -> ExtensionServiceRuntime {
    final class BundleAnchor {}
    return ExtensionServiceRuntime(
        id: "seoAudit", role: "app", bundle: Bundle(for: BundleAnchor.self)
    ) { SEOAuditExtensionService(runtime: $0) }
}

@_cdecl("edith_extension_create")
public func createExtensionRuntime() -> UnsafeMutableRawPointer? {
    UnsafeMutableRawPointer(
        bitPattern: MainActor.assumeIsolated {
            UInt(bitPattern: Unmanaged.passRetained(makeSEOAuditRuntime()).toOpaque())
        })
}
