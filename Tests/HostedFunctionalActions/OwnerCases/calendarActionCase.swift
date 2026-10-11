import Foundation
import FunctionalActionContract

@MainActor
final class CalendarActionCase: HostedFunctionalActionCase {
    static let owner = "calendar"
    static let activationOperation = "calendar.ui.action"
    static let blockingReason = "The original Calendar Details button changes row-local expanded state without engine IPC. The stable driver requires a completed original mutation acknowledgement, so calendar.ui.action would incorrectly substitute Open or Join. Calendar fixture admission also requires a remote host identity and synthetic-data home that conflict with this worker context. Central original-control observation and retained synthetic agenda-note fixture admission are required to press Details and read the same notes before mutation after update and reinstall."
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
        var errorDescription: String? { CalendarActionCase.blockingReason }
    }
}
