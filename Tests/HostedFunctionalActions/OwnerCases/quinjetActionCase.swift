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
        await model.read()
        guard model.error == nil, model.state != nil else { throw HostedFunctionalActionError.invalid }
        let count = transport.originalInvocationCount
        model.setTheme(QuinjetThemePreference.app)
        try await transport.waitForOriginalInvocation(Self.activationOperation, after: count)
    }

    func readAuthoritativeState(context: HostedFunctionalActionContext) async throws -> Data {
        guard context == transport.context else { throw HostedFunctionalActionError.invalid }
        let bytes = try await transport.readAuthoritative("quinjet.settings.read")
        let value = try JSONDecoder().decode(QuinjetSettingsState.self, from: bytes)
        try value.validate()
        guard value.preference.theme == QuinjetThemePreference.app else {
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
