import EdithExtensionSupport
import Foundation
import FunctionalActionContract

@testable import PluginsExtension

@MainActor
final class PluginsActionCase: HostedFunctionalActionCase {
    static let owner = "plugins"
    static let activationOperation = "plugins.ui.action"
    private let transport: HostedFunctionalActionTransport

    struct Blocked: LocalizedError {
        var errorDescription: String? {
            "Original runtime denies plugins.ui operations in WorkerFixtureAdmission mode and refuses fixture configureUI. Running the live installer or scanning account directories is outside this case capability. A production fixture admission change must be authorized centrally."
        }
    }

    init(transport: HostedFunctionalActionTransport) throws {
        let context = transport.context
        let environment = ProcessInfo.processInfo.environment
        guard context.owner == Self.owner,
            environment["EDITH_APPLICATION_IDENTIFIER"] == context.hostIdentifier,
            environment["EDITH_EXTENSION_FIXTURE_HOME"] == context.home,
            environment["HOME"] == context.home,
            environment["CFFIXED_USER_HOME"] == context.home,
            environment["EDITH_SHARED_DEFAULTS_SUITE"]
                == context.hostIdentifier + ".functional.ui." + Self.owner + "." + context.phase
        else { throw HostedFunctionalActionError.invalid }
        self.transport = transport
    }

    func activateOriginalControl(context: HostedFunctionalActionContext) async throws {
        guard context == transport.context else { throw HostedFunctionalActionError.invalid }
        try await transport.requireCurrent()
        throw Blocked()
    }

    func readAuthoritativeState(context: HostedFunctionalActionContext) async throws -> Data {
        guard context == transport.context else { throw HostedFunctionalActionError.invalid }
        try await transport.requireCurrent()
        throw Blocked()
    }

    func readPersistentState(context: HostedFunctionalActionContext) async throws -> Data? {
        guard context == transport.context else { throw HostedFunctionalActionError.invalid }
        try await transport.requireCurrent()
        throw Blocked()
    }

    func shutdownPresentation() async {}
}
