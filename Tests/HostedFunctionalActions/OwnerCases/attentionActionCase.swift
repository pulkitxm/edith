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
        guard model.loaded, model.errorMessage == nil, !model.settings.isEnabled,
            !model.settings.trackingEnabled, !model.settings.browserTrackingEnabled,
            model.settings.idleThreshold.isFinite, (0...86400).contains(model.settings.idleThreshold)
        else { throw HostedFunctionalActionError.invalid }
        let retained = model.settings.idleThreshold
        let baseline = try await readState(context: context, idleThreshold: retained)
        let temporary = retained == 86400 ? retained - 1 : retained + 1
        try await save(idleThreshold: temporary)
        let changed = try await readState(context: context, idleThreshold: temporary)
        guard changed != baseline else { throw HostedFunctionalActionError.invalid }
        try await save(idleThreshold: retained)
        guard try await readState(context: context, idleThreshold: retained) == baseline else {
            throw HostedFunctionalActionError.invalid
        }
    }

    private func save(idleThreshold: TimeInterval) async throws {
        model.settings.idleThreshold = idleThreshold
        model.message = nil
        let count = transport.originalInvocationCount
        model.save()
        try await transport.waitForOriginalInvocation(Self.activationOperation, after: count)
        let deadline = ContinuousClock.now + .seconds(10)
        while model.message == nil, model.errorMessage == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        guard model.message != nil, model.errorMessage == nil,
            model.settings.idleThreshold == idleThreshold
        else { throw HostedFunctionalActionError.invalid }
    }

    func readAuthoritativeState(context: HostedFunctionalActionContext) async throws -> Data {
        try await readState(context: context, idleThreshold: model.settings.idleThreshold)
    }

    private func readState(context: HostedFunctionalActionContext, idleThreshold: TimeInterval) async throws -> Data {
        guard context == transport.context else { throw HostedFunctionalActionError.invalid }
        let value = try AttentionPayload.decode(
            AttentionSettings.self,
            from: await transport.readAuthoritative("attention.settings.get"))
        guard !value.isEnabled, !value.trackingEnabled, !value.browserTrackingEnabled,
            value.idleThreshold == idleThreshold else {
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
