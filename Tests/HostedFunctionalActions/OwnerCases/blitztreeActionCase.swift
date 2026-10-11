import EdithExtensionSupport
import Foundation
import FunctionalActionContract

@testable import BlitzTreeExtension

@MainActor
final class BlitzTreeActionCase: HostedFunctionalActionCase {
    static let owner = "blitztree"
    static let activationOperation = "blitztree.ui.trash"
    private let transport: HostedFunctionalActionTransport

    struct Blocked: LocalizedError {
        var errorDescription: String? {
            "Original trash callback calls FileManager.trashItem, whose destination is not a capability-admitted private path. HOME isolation alone cannot pin macOS Trash ownership. A centrally authorized injected private trash adapter and independent owned-file reader are required."
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
