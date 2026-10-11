import EdithExtensionSupport
import Foundation
import FunctionalActionContract

@testable import HerdrUI

@MainActor
final class HerdrActionCase: HostedFunctionalActionCase {
    static let owner = "herdr"
    static let activationOperation = "herdr.settings.save"
    private let transport: HostedFunctionalActionTransport
    private let model: HerdrSettingsModel

    init(transport: HostedFunctionalActionTransport) throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["HOME"] == transport.context.home,
            environment["CFFIXED_USER_HOME"] == transport.context.home,
            environment["EDITH_EXTENSION_DATA_ROOT"] == transport.context.dataDirectory,
            environment["EDITH_SHARED_DEFAULTS_SUITE"] == transport.context.hostIdentifier + ".functional.ui." + Self.owner + "." + transport.context.phase
        else { throw HostedFunctionalActionError.invalid }
        guard transport.context.owner == Self.owner else { throw HostedFunctionalActionError.invalid }
        self.transport = transport
        model = HerdrSettingsModel { operation, payload in
            try await transport.invokeOriginal(operation, payload: payload)
        }
    }

    func activateOriginalControl(context: HostedFunctionalActionContext) async throws {
        guard context == transport.context else { throw HostedFunctionalActionError.invalid }
        await model.read()
        guard model.error == nil, !model.loading, !model.settings.monitoring,
            !model.settings.stuck, !model.settings.openDiff
        else { throw HostedFunctionalActionError.invalid }
        let count = transport.originalInvocationCount
        model.update { $0.stuckMinutes = 17 }
        try await transport.waitForOriginalInvocation(Self.activationOperation, after: count)
    }

    func readAuthoritativeState(context: HostedFunctionalActionContext) async throws -> Data {
        guard context == transport.context else { throw HostedFunctionalActionError.invalid }
        let bytes = try await transport.readAuthoritative("herdr.settings.read")
        let value = try AgentPayload.decode(HerdrAttentionSettings.self, from: bytes)
        guard value.stuckMinutes == 17, !value.monitoring, !value.stuck, !value.openDiff else {
            throw HostedFunctionalActionError.invalid
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    func readPersistentState(context: HostedFunctionalActionContext) async throws -> Data? {
        try await readAuthoritativeState(context: context)
    }

    func shutdownPresentation() async { model.shutdown() }
}
