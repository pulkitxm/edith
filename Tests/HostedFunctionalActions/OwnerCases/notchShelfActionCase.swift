import EdithExtensionSupport
import Foundation
import FunctionalActionContract

@testable import NotchShelfExtension

@MainActor
final class NotchShelfActionCase: HostedFunctionalActionCase {
    static let owner = "notchShelf"
    static let activationOperation = "notch.settings.write"
    private let transport: HostedFunctionalActionTransport

    struct Blocked: LocalizedError {
        var errorDescription: String? {
            "Original fixture start returns before constructing the shelf controller. Original invoke rejects all notch settings operations when fixture admission is present, and original view rejects fixture mode. Centrally authorized fixture settings admission is required before this original control can execute."
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
