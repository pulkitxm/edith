import EdithExtensionSupport
import Foundation
import FunctionalActionContract

@testable import QuinjetUI

@MainActor
final class QuinjetActionCase: HostedFunctionalActionCase {
    static let owner = "quinjet"
    static let activationOperation = "quinjet.settings.save"
    private let transport: HostedFunctionalActionTransport
    private let model: QuinjetSettingsModel

    init(transport: HostedFunctionalActionTransport) throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["HOME"] == transport.context.home,
            environment["CFFIXED_USER_HOME"] == transport.context.home,
            environment["EDITH_EXTENSION_DATA_ROOT"] == transport.context.dataDirectory,
            environment["EDITH_SHARED_DEFAULTS_SUITE"] == transport.context.hostIdentifier + ".functional.ui." + Self.owner + "." + transport.context.phase
        else { throw HostedFunctionalActionError.invalid }
        guard transport.context.owner == Self.owner else { throw HostedFunctionalActionError.invalid }
        self.transport = transport
        model = QuinjetSettingsModel { operation, payload in
            try await transport.invokeOriginal(operation, payload: payload)
        }
    }

    func activateOriginalControl(context: HostedFunctionalActionContext) async throws {
        guard context == transport.context else { throw HostedFunctionalActionError.invalid }
        let baseline = try await readState(context: context, theme: QuinjetThemePreference.app)
        await model.read()
        guard model.error == nil, let state = model.state,
            state.preference.theme == QuinjetThemePreference.app,
            let temporary = state.themes.first(where: { $0 != state.preference.theme })
        else { throw HostedFunctionalActionError.invalid }
        try await save(theme: temporary)
        let changed = try await readState(context: context, theme: temporary)
        guard changed != baseline else { throw HostedFunctionalActionError.invalid }
        try await save(theme: QuinjetThemePreference.app)
        guard try await readState(context: context, theme: QuinjetThemePreference.app) == baseline else {
            throw HostedFunctionalActionError.invalid
        }
    }

    private func save(theme: String) async throws {
        let count = transport.originalInvocationCount
        model.setTheme(theme)
        try await transport.waitForOriginalInvocation(Self.activationOperation, after: count)
        let deadline = ContinuousClock.now + .seconds(10)
        while model.loading, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        guard !model.loading, model.error == nil, model.state?.preference.theme == theme else {
            throw HostedFunctionalActionError.invalid
        }
    }

    func readAuthoritativeState(context: HostedFunctionalActionContext) async throws -> Data {
        try await readState(context: context, theme: QuinjetThemePreference.app)
    }

    private func readState(context: HostedFunctionalActionContext, theme: String) async throws -> Data {
        guard context == transport.context else { throw HostedFunctionalActionError.invalid }
        let bytes = try await transport.readAuthoritative("quinjet.settings.read")
        let value = try JSONDecoder().decode(QuinjetSettingsState.self, from: bytes)
        try value.validate()
        guard value.preference.theme == theme else {
            throw HostedFunctionalActionError.invalid
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value.preference)
    }

    func readPersistentState(context: HostedFunctionalActionContext) async throws -> Data? {
        try await readAuthoritativeState(context: context)
    }

    func shutdownPresentation() async { model.shutdown() }
}
