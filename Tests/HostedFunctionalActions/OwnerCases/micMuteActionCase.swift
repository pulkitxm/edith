import EdithExtensionSupport
import Foundation
import FunctionalActionContract

@testable import MicMuteExtension

@MainActor
final class MicMuteActionCase: HostedFunctionalActionCase {
    static let owner = "micMute"
    static let activationOperation = "micMute.ui.action"
    private let transport: HostedFunctionalActionTransport
    private let presentation: ControlPresentation

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
        presentation = ControlPresentation(client: try transport.makeEngineClient())
    }

    func activateOriginalControl(context: HostedFunctionalActionContext) async throws {
        guard context == transport.context else { throw HostedFunctionalActionError.invalid }
        try await transport.requireCurrent()
        await presentation.refresh()
        guard presentation.ready, presentation.active else {
            throw HostedFunctionalActionError.invalid
        }
        if presentation.state.muted {
            let before = transport.originalInvocationCount
            presentation.perform("unmute")
            try await transport.waitForOriginalInvocation(Self.activationOperation, after: before)
            await Task.yield()
        }
        let before = transport.originalInvocationCount
        presentation.perform("mute")
        try await transport.waitForOriginalInvocation(Self.activationOperation, after: before)
    }

    func readAuthoritativeState(context: HostedFunctionalActionContext) async throws -> Data {
        guard context == transport.context else { throw HostedFunctionalActionError.invalid }
        try await transport.requireCurrent()
        let request = SurfaceSnapshotRequest(target: .home, tile: SurfaceTile(.ability(Self.owner)))
        let bytes = try await transport.readAuthoritative(
            "surface.snapshot", payload: request.encoded(providerID: Self.owner))
        let snapshot = try SurfaceSnapshot.decode(bytes, providerID: Self.owner)
        guard snapshot.rows.first(where: { $0.id == "microphone" })?.value == "Muted",
            snapshot.message == nil
        else {
            throw HostedFunctionalActionError.invalid
        }
        return bytes
    }

    func readPersistentState(context: HostedFunctionalActionContext) async throws -> Data? {
        guard context == transport.context else { throw HostedFunctionalActionError.invalid }
        try await transport.requireCurrent()
        let bytes = try await transport.readAuthoritative("micMute.ui.read")
        let packet = try JSONDecoder().decode(ControlPresentationPacket.self, from: bytes)
        guard packet.state.muted, packet.state.error == nil else {
            throw HostedFunctionalActionError.invalid
        }
        return try JSONSerialization.data(
            withJSONObject: ["muted": packet.state.muted], options: [.sortedKeys])
    }

    func shutdownPresentation() async {
        presentation.stop()
    }
}
