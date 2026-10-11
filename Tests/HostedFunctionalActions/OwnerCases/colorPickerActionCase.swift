import EdithExtensionSupport
import Foundation
import FunctionalActionContract

@testable import ColorPickerExtension

@MainActor
final class ColorPickerActionCase: HostedFunctionalActionCase {
    static let owner = "colorPicker"
    static let activationOperation = "colorPicker.ui.action"
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
        guard
            SharedDefaults.store.string(forKey: "colorPickerProfile") == nil
                || SharedDefaults.store.string(forKey: "colorPickerProfile") == "sRGB"
        else { throw HostedFunctionalActionError.invalid }
        let before = transport.originalInvocationCount
        presentation.perform("pick")
        try await transport.waitForOriginalInvocation(Self.activationOperation, after: before)
    }

    func readAuthoritativeState(context: HostedFunctionalActionContext) async throws -> Data {
        guard context == transport.context else { throw HostedFunctionalActionError.invalid }
        try await transport.requireCurrent()
        let request = SurfaceSnapshotRequest(target: .home, tile: SurfaceTile(.ability(Self.owner)))
        let bytes = try await transport.readAuthoritative(
            "surface.snapshot", payload: request.encoded(providerID: Self.owner))
        let snapshot = try SurfaceSnapshot.decode(bytes, providerID: Self.owner)
        guard snapshot.rows.first?.title == "#4080BF", snapshot.message == nil else {
            throw HostedFunctionalActionError.invalid
        }
        return bytes
    }

    func readPersistentState(context: HostedFunctionalActionContext) async throws -> Data? {
        guard context == transport.context else { throw HostedFunctionalActionError.invalid }
        try await transport.requireCurrent()
        let bytes = try await transport.readAuthoritative("colorPicker.ui.read")
        let packet = try JSONDecoder().decode(ControlPresentationPacket.self, from: bytes)
        let values = try ControlPresentationContract.decode(
            packet.preferences, keys: ControlPresentationContract.readable)
        guard let data = values["colorPickerHistory"] as? Data else {
            throw HostedFunctionalActionError.invalid
        }
        let history = try JSONDecoder().decode([ColorSwatch].self, from: data)
        guard let retained = history.last, retained.profile == .sRGB,
            abs(retained.red - 0.25) < 0.001, abs(retained.green - 0.5) < 0.001,
            abs(retained.blue - 0.75) < 0.001
        else { throw HostedFunctionalActionError.invalid }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(retained)
    }

    func shutdownPresentation() async {
        presentation.stop()
    }
}
