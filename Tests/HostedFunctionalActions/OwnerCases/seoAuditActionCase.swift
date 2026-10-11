import EdithExtensionSupport
import Foundation
import FunctionalActionContract

@testable import SEOAuditExtension

@MainActor
final class SEOAuditActionCase: HostedFunctionalActionCase {
    static let owner = "seoAudit"
    static let activationOperation = "seoAudit.ui.action"
    private let transport: HostedFunctionalActionTransport
    private let model: SEOAuditModel
    private let service: SEOAuditService
    private static let projectID = UUID(uuidString: "91000000-0000-4000-8000-000000000001")!

    init(transport: HostedFunctionalActionTransport) throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["HOME"] == transport.context.home,
            environment["CFFIXED_USER_HOME"] == transport.context.home,
            environment["EDITH_EXTENSION_DATA_ROOT"] == transport.context.dataDirectory,
            environment["EDITH_SHARED_DEFAULTS_SUITE"] == transport.context.hostIdentifier + ".functional.ui." + Self.owner + "." + transport.context.phase
        else { throw HostedFunctionalActionError.invalid }
        guard transport.context.owner == Self.owner else { throw HostedFunctionalActionError.invalid }
        self.transport = transport
        let bridge = SEOAuditUIBridge { operation, payload in
            try await transport.invokeOriginal(operation, payload: payload)
        }
        service = SEOAuditService(remote: bridge)
        model = SEOAuditModel(service: service)
    }

    func activateOriginalControl(context: HostedFunctionalActionContext) async throws {
        guard context == transport.context else { throw HostedFunctionalActionError.invalid }
        let baseline = try await readState(context: context, name: "Synthetic retained audit")
        var count = transport.originalInvocationCount
        await model.renameProject(id: Self.projectID, to: "Synthetic temporary audit")
        try await transport.waitForOriginalInvocation(Self.activationOperation, after: count)
        guard model.errorMessage == nil else { throw HostedFunctionalActionError.invalid }
        let changed = try await readState(context: context, name: "Synthetic temporary audit")
        guard changed != baseline else { throw HostedFunctionalActionError.invalid }
        count = transport.originalInvocationCount
        await model.renameProject(id: Self.projectID, to: "Synthetic retained audit")
        try await transport.waitForOriginalInvocation(Self.activationOperation, after: count)
        guard model.errorMessage == nil,
            try await readState(context: context, name: "Synthetic retained audit") == baseline
        else { throw HostedFunctionalActionError.invalid }
    }

    func readAuthoritativeState(context: HostedFunctionalActionContext) async throws -> Data {
        try await readState(context: context, name: "Synthetic retained audit")
    }

    private func readState(context: HostedFunctionalActionContext, name: String) async throws -> Data {
        guard context == transport.context else { throw HostedFunctionalActionError.invalid }
        try await transport.requireCurrent()
        let file = try context.ownedPath(named: "seo-project", kind: "file")
        let root = try context.ownedPath(named: "seo-store", kind: "directory")
        guard root == URL(fileURLWithPath: context.dataDirectory).appendingPathComponent("SEOAudit"),
            file == root.appendingPathComponent("project-" + Self.projectID.uuidString.lowercased() + ".json"),
            let bytes = SEOAuditOwnedIO.read(file, root: root),
            let value = try? JSONDecoder().decode(SEOAuditProject.self, from: bytes),
            value.id == Self.projectID, value.name == name, value.runs.isEmpty
        else { throw HostedFunctionalActionError.invalid }
        try await transport.requireCurrent()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(value)
        guard var semantic = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
            throw HostedFunctionalActionError.invalid
        }
        semantic.removeValue(forKey: "updatedAt")
        return try JSONSerialization.data(withJSONObject: semantic, options: [.sortedKeys])
    }

    func readPersistentState(context: HostedFunctionalActionContext) async throws -> Data? {
        try await readAuthoritativeState(context: context)
    }

    func shutdownPresentation() async {
        model.shutdown()
        await model.drain()
        await service.shutdown()
    }
}
