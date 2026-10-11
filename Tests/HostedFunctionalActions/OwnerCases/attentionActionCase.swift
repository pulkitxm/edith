import Foundation
import FunctionalActionContract

@testable import AttentionNative

@MainActor
final class AttentionActionCase: HostedFunctionalActionCase {
    static let owner = "attention"
    static let activationOperation = "attention.settings.set"
    private let transport: HostedFunctionalActionTransport
    private let model: AttentionTrackingSettingsModel

    init(transport: HostedFunctionalActionTransport) throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["HOME"] == transport.context.home,
            environment["CFFIXED_USER_HOME"] == transport.context.home,
            environment["EDITH_EXTENSION_DATA_ROOT"] == transport.context.dataDirectory,
            environment["EDITH_SHARED_DEFAULTS_SUITE"] == transport.context.hostIdentifier + ".functional.ui." + Self.owner + "." + transport.context.phase
        else { throw HostedFunctionalActionError.invalid }
        guard transport.context.owner == Self.owner else { throw HostedFunctionalActionError.invalid }
        self.transport = transport
        let client = AttentionUIClient(send: { operation, payload in
            try await transport.invokeOriginal(operation, payload: payload)
        })
        model = AttentionTrackingSettingsModel(client: client)
    }

    func activateOriginalControl(context: HostedFunctionalActionContext) async throws {
        guard context == transport.context else { throw HostedFunctionalActionError.invalid }
        await model.load()
        guard model.loaded, model.errorMessage == nil else { throw HostedFunctionalActionError.invalid }
        model.settings.trackingEnabled = false
        model.settings.browserTrackingEnabled = false
        let count = transport.originalInvocationCount
        model.save()
        try await transport.waitForOriginalInvocation(Self.activationOperation, after: count)
    }

    func readAuthoritativeState(context: HostedFunctionalActionContext) async throws -> Data {
        guard context == transport.context else { throw HostedFunctionalActionError.invalid }
        let value = try AttentionPayload.decode(
            AttentionSettings.self,
            from: await transport.readAuthoritative("attention.settings.get"))
        guard !value.isEnabled, !value.trackingEnabled, !value.browserTrackingEnabled else {
            throw HostedFunctionalActionError.invalid
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    func readPersistentState(context: HostedFunctionalActionContext) async throws -> Data? {
        try await readAuthoritativeState(context: context)
    }

    func shutdownPresentation() async { model.stop() }
}
