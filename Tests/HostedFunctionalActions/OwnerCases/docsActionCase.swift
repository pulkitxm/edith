import Foundation
import FunctionalActionContract

@MainActor
final class DocsActionCase: HostedFunctionalActionCase {
    static let owner = "docs"
    static let activationOperation = "docs.ui.ask"
    static let blockingReason = "Docs Ask computes a stateless result without retaining it in the engine. docs.ui.library is unrelated content; repeating docs.ui.ask would echo the same request. External follow opens a system browser without an admitted independent observer. A reviewed original-action observation helper is required."
    private let transport: HostedFunctionalActionTransport

    init(transport: HostedFunctionalActionTransport) throws {
        guard transport.context.owner == Self.owner else { throw HostedFunctionalActionError.invalid }
        self.transport = transport
    }

    func activateOriginalControl(context: HostedFunctionalActionContext) async throws {
        let _: Void = try fail(context)
    }

    func readAuthoritativeState(context: HostedFunctionalActionContext) async throws -> Data {
        try fail(context)
    }

    func readPersistentState(context: HostedFunctionalActionContext) async throws -> Data? {
        try fail(context)
    }

    func shutdownPresentation() async {}

    private func fail<T>(_ context: HostedFunctionalActionContext) throws -> T {
        guard context == transport.context else { throw HostedFunctionalActionError.invalid }
        throw Blocked()
    }

    private struct Blocked: LocalizedError {
        var errorDescription: String? { DocsActionCase.blockingReason }
    }
}
