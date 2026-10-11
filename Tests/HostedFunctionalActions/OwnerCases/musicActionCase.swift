import Foundation
import FunctionalActionContract

@MainActor
final class MusicActionCase: HostedFunctionalActionCase {
    static let owner = "music"
    static let activationOperation = "music.ui.action"
    static let blockingReason = "Music Runtime.invoke rejects all commands in the admitted inert fixture. An active synthetic mode with the real sidecar history and preference paths is required; bypassing fixture admission would allocate account and playback resources."
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
        var errorDescription: String? { MusicActionCase.blockingReason }
    }
}
