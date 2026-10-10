import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import SwiftUI

@MainActor @objc(EdithSEOAuditExtensionRuntime)
final class ExtensionRuntime: NSObject {
    private var service: SEOAuditService?
    private var operations: SEOAuditCommands?
    private var surface: SEOAuditSurface?
    private var startup: Task<Void, Never>?
    private let commands = ExtensionCommandRegistry()
    private var fixture: Bool {
        ProcessInfo.processInfo.environment["EDITH_EXTENSION_FIXTURE_HOME"] != nil
    }

    @objc func invoke(_ request: NSDictionary, completion: @escaping (NSData?, NSString?) -> Void) {
        commands.invoke(request, completion: completion) { [weak self] command, payload in
            guard let self, self.service != nil else { throw ExtensionPeerError.unavailable }
            await self.startup?.value
            try Task.checkCancellation()
            if command.hasPrefix("surface."), let surface = self.surface {
                return try await surface.execute(command, payload: payload)
            }
            guard let operations = self.operations else { throw ExtensionPeerError.unavailable }
            return try await operations.execute(command, payload: payload)
        }
    }

    @objc(prepareToStopWithCompletion:)
    func prepareToStop(completion: @escaping () -> Void) {
        guard service != nil else { commands.shutdown(); completion(); return }
        commands.shutdown(); startup?.cancel()
        SEOAuditModel.shared.shutdown(); SEOAuditPrivacyState.shared.shutdown()
        SEOSnapshotCache.shared.shutdown(); SEOAuditWorkerOperations.service = nil
        operations?.shutdown(); operations = nil; surface = nil
        let service = service; self.service = nil
        let startup = startup; self.startup = nil
        Task {
            await service?.shutdown()
            await startup?.value
            await SEOAuditModel.shared.drain()
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
        case "start":
            guard let suite = input["defaultsSuite"] as? String,
                suite == ProcessInfo.processInfo.environment["EDITH_SHARED_DEFAULTS_SUITE"]
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
            operations = SEOAuditCommands(service: service);
            surface = SEOAuditSurface(service: service)
            SEOSnapshotCache.shared.configure(root: root, network: network)
            startup = Task { await SEOAuditModel.shared.refreshProjects() }
        case "view":
            guard service != nil else { return ["ok": false] as NSDictionary }
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
}

@_cdecl("edith_extension_create")
public func createExtensionRuntime() -> UnsafeMutableRawPointer? {
    UnsafeMutableRawPointer(
        bitPattern: MainActor.assumeIsolated {
            UInt(bitPattern: Unmanaged.passRetained(ExtensionRuntime()).toOpaque())
        })
}
