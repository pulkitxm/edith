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
        let baseline = try await readState(context: context, reasonModel: "qwen3:1.7b")
        await model.refreshSnapshot()
        guard model.hosts.isEmpty, model.deployment == nil, model.selectedHostID == nil,
            model.error == nil, model.config.reasonModel == "qwen3:1.7b"
        else { throw HostedFunctionalActionError.invalid }
        try await save(reasonModel: "synthetic-temporary-reason-model")
        let changed = try await readState(context: context, reasonModel: "synthetic-temporary-reason-model")
        guard changed != baseline else { throw HostedFunctionalActionError.invalid }
        try await save(reasonModel: "qwen3:1.7b")
        guard try await readState(context: context, reasonModel: "qwen3:1.7b") == baseline else {
            throw HostedFunctionalActionError.invalid
        }
    }

    private func save(reasonModel: String) async throws {
        guard model.selectedHostID == nil else { throw HostedFunctionalActionError.invalid }
        model.config.reasonModel = reasonModel
        let count = transport.originalInvocationCount
        model.saveConfig()
        try await transport.waitForOriginalInvocation(Self.activationOperation, after: count)
        let deadline = ContinuousClock.now + .seconds(10)
        while model.config.reasonModel != reasonModel, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        guard model.error == nil, !model.configStatusIsError,
            model.config.reasonModel == reasonModel
        else { throw HostedFunctionalActionError.invalid }
    }

    func readAuthoritativeState(context: HostedFunctionalActionContext) async throws -> Data {
        try await readState(context: context, reasonModel: "qwen3:1.7b")
    }

    private func readState(context: HostedFunctionalActionContext, reasonModel: String) async throws -> Data {
        guard context == transport.context else { throw HostedFunctionalActionError.invalid }
        try await transport.requireCurrent()
        let path = try context.ownedPath(named: "companion-config", kind: "file")
        guard path.path == URL(fileURLWithPath: context.dataDirectory).appendingPathComponent("companion-config.json").path,
            path.standardizedFileURL == path.resolvingSymlinksInPath(),
            let value = try PersistentJSONFile.read(CompanionStackConfig?.self, from: path, missing: nil),
            value.reasonModel == reasonModel, value.validated().isEmpty
        else { throw HostedFunctionalActionError.invalid }
        try await transport.requireCurrent()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    func readPersistentState(context: HostedFunctionalActionContext) async throws -> Data? {
        try await readAuthoritativeState(context: context)
    }

    func shutdownPresentation() async { await model.cancelAndWait() }
}
