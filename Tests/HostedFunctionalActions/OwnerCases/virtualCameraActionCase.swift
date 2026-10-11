import Foundation
import FunctionalActionContract

@MainActor
final class VirtualCameraActionCase: HostedFunctionalActionCase {
    static let owner = "virtualCamera"
    static let activationOperation = "camera.ui.state"
    static let blockingReason = "OBS workaround carrier and privileged role source interactions require independently admitted carrier/role PID, birth, executable and selected-source identities. This context admits engine/UI only. camera.snapshot flags from CameraOBSFixtureHardware cannot prove physical camera, OBS hardware visibility, or installed privileged plugin behavior. Central role admission and observation helpers are required."
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
        var errorDescription: String? { VirtualCameraActionCase.blockingReason }
    }
}
