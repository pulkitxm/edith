import Foundation
import FunctionalActionContract

@MainActor
final class StudioActionCase: HostedFunctionalActionCase {
    static let owner = "studio"
    static let activationOperation = "studio.ui.video.export"
    static let blockingReason = "Studio Runtime.invoke permits only surface.snapshot and studio.tools.list/schema in its admitted fixture, rejecting original video export. A reviewed active synthetic fixture and original save-panel destination helper are required. The completion gate remains 120 clips, 3600 encoded frames, and completion within 30 seconds; a tool listing or a small export cannot satisfy it."
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
        var errorDescription: String? { StudioActionCase.blockingReason }
    }
}
