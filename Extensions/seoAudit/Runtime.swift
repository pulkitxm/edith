import AppKit
import EdithExtensionSupport
import EdithExtensionCommands
import EdithExtensionUI
import Foundation
import SwiftUI

@MainActor @objc(EdithSEOAuditExtensionRuntime)
final class ExtensionRuntime: NSObject {
    private var service: SEOAuditService?
    private var uiService: SEOAuditService?
    private var uiEngine: SEOAuditUIEngine?
    private var engineClient: ExtensionEngineClient?
    private var operations: SEOAuditCommands?
    private var surface: SEOAuditSurface?
    private var startup: Task<Void, Never>?
    private let commands = ExtensionCommandRegistry()
    private var cliStreams: ExtensionCLIStreams?
    private var draining = false
    private var uiStops: [UUID: Task<Void, Never>] = [:]
    private var fixture: Bool {
        ExtensionEnvironment.values["EDITH_EXTENSION_FIXTURE_HOME"] != nil
    }

    @objc func invoke(_ request: NSDictionary, completion: @escaping (NSData?, NSString?) -> Void) {
        commands.invoke(request, completion: completion) { [weak self] command, payload in
            guard let self, self.service != nil else { throw ExtensionPeerError.unavailable }
            await self.startup?.value
            try Task.checkCancellation()
            if command == "seoAudit.cli.catalog" {
                return try ExtensionCLICatalog.data(
                    SEOCommand.self, owner: "seoAudit", payload: payload, streaming: true)
            }
            if command.hasPrefix("seoAudit.cli.") {
                guard let service = self.service else { throw ExtensionPeerError.unavailable }
                if self.cliStreams == nil {
                    self.cliStreams = try ExtensionCLIStreams(owner: "seoAudit")
                }
                guard let streams = self.cliStreams else { throw ExtensionPeerError.unavailable }
                return try SEOCLIExecution.stream(
                    streams, operation: command, payload: payload, service: service)
            }
            if command == "seoAudit.cli", let service = self.service {
                let request = try JSONDecoder().decode(ExtensionCLIRequest.self, from: payload)
                return try JSONEncoder().encode(
                    try await SEOCLIExecution.run(request, service: service))
            }
            if command.hasPrefix("seoAudit.ui."), let engine = self.uiEngine {
                return try await engine.execute(command, payload: payload)
            }
            if command.hasPrefix("surface."), let surface = self.surface {
                return try await surface.execute(command, payload: payload)
            }
            guard let operations = self.operations else { throw ExtensionPeerError.unavailable }
            return try await operations.execute(command, payload: payload)
        }
    }

    @objc(suspendCommandsWithCompletion:)
    func suspendCommands(completion: @escaping () -> Void) {
        _ = commands.suspend()
        draining = true
        let service = service, uiService = uiService, startup = startup, streams = cliStreams
        let model = SEOAuditModel.shared, engine = uiEngine
        engine?.shutdown()
        startup?.cancel()
        streams?.stop()
        service?.beginSuspension()
        uiService?.beginSuspension()
        model.shutdown()
        Task { [self, service, uiService, startup, streams, model, engine] in
            _ = await commands.suspendAndWait()
            await startup?.value
            await streams?.stopAndWait()
            await service?.suspendAndWait()
            await uiService?.suspendAndWait()
            await model.suspendAndWait()
            await engine?.suspendAndWait()
            for task in Array(uiStops.values) { await task.value }
            completion()
        }
    }

    @objc(prepareToStopWithCompletion:)
    func prepareToStop(completion: @escaping () -> Void) {
        draining = true
        stopUI()
        let streams = cliStreams; cliStreams = nil; streams?.stop()
        commands.shutdown(); startup?.cancel()
        let engine = uiEngine
        engine?.shutdown(); uiEngine = nil
        SEOAuditModel.shared.shutdown(); SEOAuditPrivacyState.shared.shutdown()
        SEOSnapshotCache.shared.shutdown(); SEOAuditWorkerOperations.service = nil
        operations?.shutdown(); operations = nil; surface = nil
        let service = service; self.service = nil
        service?.beginSuspension()
        let model = SEOAuditModel.shared
        let startup = startup; self.startup = nil
        Task { [self, service, startup, streams, model, engine] in
            await service?.shutdown()
            await startup?.value
            await model.drain()
            await engine?.shutdownAndWait()
            await streams?.stopAndWait()
            await commands.shutdownAndWait()
            for task in Array(uiStops.values) { await task.value }
            completion()
        }
    }

    @objc func execute(_ input: NSDictionary) -> NSObject {
        switch input["operation"] as? String {
        case "describe":
            let bundle = Bundle(for: ExtensionRuntime.self)
            return [
                "id": "seoAudit", "role": "app",
                "version": bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                    as? String ?? "",
                "hostABI": bundle.object(forInfoDictionaryKey: "EdithHostABI") as? String ?? "",
            ] as NSDictionary
        case "configureUI":
            guard !draining, uiStops.isEmpty, engineClient == nil,
                let configuration = ExtensionUIConfiguration(context: input),
                configuration.extensionID == "seoAudit", let client = configuration.engineClient
            else { return ["ok": false] as NSDictionary }
            engineClient = client
            let bridge = SEOAuditUIBridge(client: client)
            let service = SEOAuditService(remote: bridge)
            uiService = service
            SEOAuditModel.shared = SEOAuditModel(service: service)
            SEOSnapshotCache.shared.configureRemote {
                try await bridge.call("image", url: $0, as: Data?.self)
            }
        case "stopUI": stopUI()
        case "start":
            guard !draining, let suite = input["defaultsSuite"] as? String,
                suite == ExtensionEnvironment.values["EDITH_SHARED_DEFAULTS_SUITE"]
            else { return ["ok": false] as NSDictionary }
            guard service == nil else { return ["ok": true] as NSDictionary }
            let root = ExtensionData.root.appendingPathComponent("SEOAudit", isDirectory: true)
            let network = SEOAuditHTTPClient(restrictToLoopback: fixture)
            let lighthouse = fixture ? LighthouseAuditor(locate: { nil }) : LighthouseAuditor()
            let workflow = SEOAuditWorkflow(
                repository: SEOAuditRepository(root: root), network: network, lighthouse: lighthouse
            )
            let service = SEOAuditService(workflow: workflow)
            self.service = service; SEOAuditWorkerOperations.service = service
            uiEngine = SEOAuditUIEngine(service: service)
            operations = SEOAuditCommands(service: service);
            surface = SEOAuditSurface(service: service)
            SEOSnapshotCache.shared.configure(root: root, network: network)
            startup = Task { await SEOAuditModel.shared.refreshProjects() }
        case "view":
            guard uiService != nil else { return ["ok": false] as NSDictionary }
            let automatic = !fixture
            return NSHostingController(
                rootView: ExtensionPageHost {
                    SEOAuditPage().environment(\.automaticViewActionsEnabled, automatic)
                })
        case "cancelCommand": commands.cancel(input["token"] as? String ?? "")
        case "stop": prepareToStop(completion: {})
        case "status": return ["ok": true, "running": service != nil] as NSDictionary
        default: return ["ok": false] as NSDictionary
        }
        return ["ok": true] as NSDictionary
    }
    private func stopUI() {
        let client = engineClient; engineClient = nil
        let service = uiService, model = SEOAuditModel.shared
        service?.beginSuspension()
        model.shutdown()
        SEOSnapshotCache.shared.shutdown()
        uiService = nil
        if service != nil {
            let id = UUID()
            uiStops[id] = Task { [self, service, model, client] in
                defer { client?.invalidate(); uiStops[id] = nil }
                await service?.shutdown()
                await model.drain()
            }
        }
        if service == nil { client?.invalidate() }
    }

}

@_cdecl("edith_extension_create")
public func createExtensionRuntime() -> UnsafeMutableRawPointer? {
    UnsafeMutableRawPointer(
        bitPattern: MainActor.assumeIsolated {
            UInt(bitPattern: Unmanaged.passRetained(ExtensionRuntime()).toOpaque())
        })
}
