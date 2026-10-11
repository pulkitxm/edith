import EdithExtensionSupport
import Foundation
import FunctionalActionContract

@testable import EmojiExtension

@MainActor
final class EmojiActionCase: HostedFunctionalActionCase {
    static let owner = "emoji"
    static let activationOperation = "emoji.ui.action"
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
        if context.phase == "initial" {
            let data = SharedDefaults.store.data(forKey: "emojiUsage")
            guard let data,
                try !JSONDecoder().decode(EmojiUsageLedger.self, from: data).entries.isEmpty
            else { throw HostedFunctionalActionError.invalid }
        }
        let before = transport.originalInvocationCount
        presentation.perform("clear")
        try await transport.waitForOriginalInvocation(Self.activationOperation, after: before)
    }

    func readAuthoritativeState(context: HostedFunctionalActionContext) async throws -> Data {
        guard context == transport.context else { throw HostedFunctionalActionError.invalid }
        try await transport.requireCurrent()
        let request = SurfaceSnapshotRequest(target: .home, tile: SurfaceTile(.ability(Self.owner)))
        let bytes = try await transport.readAuthoritative(
            "surface.snapshot", payload: request.encoded(providerID: Self.owner))
        let snapshot = try SurfaceSnapshot.decode(bytes, providerID: Self.owner)
        guard snapshot.rows.isEmpty,
            snapshot.message == "Choose an emoji to start your frequent list."
        else { throw HostedFunctionalActionError.invalid }
        return bytes
    }

    func readPersistentState(context: HostedFunctionalActionContext) async throws -> Data? {
        guard context == transport.context else { throw HostedFunctionalActionError.invalid }
        try await transport.requireCurrent()
        let bytes = try await transport.readAuthoritative("emoji.ui.read")
        let packet = try JSONDecoder().decode(ControlPresentationPacket.self, from: bytes)
        let values = try ControlPresentationContract.decode(
            packet.preferences, keys: ControlPresentationContract.readable)
        guard let data = values["emojiUsage"] as? Data else {
            throw HostedFunctionalActionError.invalid
        }
        let ledger = try JSONDecoder().decode(EmojiUsageLedger.self, from: data)
        guard ledger.entries.isEmpty else { throw HostedFunctionalActionError.invalid }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(ledger)
    }

    func shutdownPresentation() async {
        presentation.stop()
    }
}
