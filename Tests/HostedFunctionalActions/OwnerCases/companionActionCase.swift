import EdithExtensionSupport
import Foundation
import FunctionalActionContract

@testable import CompanionExtension

@MainActor
final class CompanionActionCase: HostedFunctionalActionCase {
    static let owner = "companion"
    static let activationOperation = "companion.ui.backend"
    private let transport: HostedFunctionalActionTransport
    private let model: CompanionBackendModel

    init(transport: HostedFunctionalActionTransport) throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["HOME"] == transport.context.home,
            environment["CFFIXED_USER_HOME"] == transport.context.home,
            environment["EDITH_EXTENSION_DATA_ROOT"] == transport.context.dataDirectory,
            environment["EDITH_SHARED_DEFAULTS_SUITE"] == transport.context.hostIdentifier + ".functional.ui." + Self.owner + "." + transport.context.phase
        else { throw HostedFunctionalActionError.invalid }
        guard transport.context.owner == Self.owner else { throw HostedFunctionalActionError.invalid }
        self.transport = transport
        let bridge = CompanionUIBridge { operation, payload in
            try await transport.invokeOriginal(operation, payload: payload)
        }
        model = CompanionBackendModel(remote: bridge)
    }

    func activateOriginalControl(context: HostedFunctionalActionContext) async throws {
        guard context == transport.context else { throw HostedFunctionalActionError.invalid }
        await model.refreshSnapshot()
        guard model.hosts.isEmpty, model.deployment == nil, model.error == nil else {
            throw HostedFunctionalActionError.invalid
        }
        model.config.reflectAt = "03:17"
        let count = transport.originalInvocationCount
        model.saveConfig()
        try await transport.waitForOriginalInvocation(Self.activationOperation, after: count)
    }

    func readAuthoritativeState(context: HostedFunctionalActionContext) async throws -> Data {
        guard context == transport.context else { throw HostedFunctionalActionError.invalid }
        try await transport.requireCurrent()
        let path = try context.ownedPath(named: "companion-config", kind: "file")
        guard path.path == URL(fileURLWithPath: context.dataDirectory).appendingPathComponent("companion-config.json").path,
            path.standardizedFileURL == path.resolvingSymlinksInPath(),
            let value = try PersistentJSONFile.read(CompanionStackConfig?.self, from: path, missing: nil),
            value.reflectAt == "03:17", value.validated().isEmpty
        else { throw HostedFunctionalActionError.invalid }
        try await transport.requireCurrent()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    func readPersistentState(context: HostedFunctionalActionContext) async throws -> Data? {
        try await readAuthoritativeState(context: context)
    }

    func shutdownPresentation() async { model.shutdown() }
}
