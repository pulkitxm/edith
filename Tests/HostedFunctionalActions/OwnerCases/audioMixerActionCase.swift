import EdithExtensionSupport
import Foundation
import FunctionalActionContract

@testable import AudioMixerExtension

@available(macOS 14.4, *)
@MainActor
final class AudioMixerActionCase: HostedFunctionalActionCase {
    static let owner = "audioMixer"
    static let activationOperation = "audioMixer.request"
    private let transport: HostedFunctionalActionTransport
    private let client: ExtensionEngineClient
    private let model: AudioMixerRemoteModel

    init(transport: HostedFunctionalActionTransport) throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["HOME"] == transport.context.home,
            environment["CFFIXED_USER_HOME"] == transport.context.home,
            environment["EDITH_EXTENSION_DATA_ROOT"] == transport.context.dataDirectory,
            environment["EDITH_SHARED_DEFAULTS_SUITE"] == transport.context.hostIdentifier + ".functional.ui." + Self.owner + "." + transport.context.phase
        else { throw HostedFunctionalActionError.invalid }
        guard transport.context.owner == Self.owner else { throw HostedFunctionalActionError.invalid }
        self.transport = transport
        client = try transport.makeEngineClient()
        model = AudioMixerRemoteModel(client: client)
    }

    func activateOriginalControl(context: HostedFunctionalActionContext) async throws {
        guard context == transport.context else { throw HostedFunctionalActionError.invalid }
        model.viewAppeared()
        let deadline = ContinuousClock.now + .seconds(10)
        while model.apps.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        guard model.apps.count == 1, let app = model.apps.first,
            app.objectID == 41, app.pid == 900, app.bundleID == "org.example.synthetic.audio",
            app.volume != 0.375
        else { throw HostedFunctionalActionError.invalid }
        let before = try JSONDecoder().decode(
            AudioMixerUISnapshot.self,
            from: await transport.readAuthoritative("audioMixer.ui.snapshot"))
        guard before.error == nil, before.apps.count == 1, let observed = before.apps.first,
            observed.objectID == app.objectID, observed.pid == app.pid,
            observed.bundleID == app.bundleID, observed.normalizedVolume != 0.375,
            Float(observed.normalizedVolume) == app.volume
        else { throw HostedFunctionalActionError.invalid }
        let count = transport.originalInvocationCount
        model.setVolume(app, 0.375)
        try await transport.waitForOriginalInvocation(Self.activationOperation, after: count)
    }

    func readAuthoritativeState(context: HostedFunctionalActionContext) async throws -> Data {
        guard context == transport.context else { throw HostedFunctionalActionError.invalid }
        let bytes = try await transport.readAuthoritative("audioMixer.ui.snapshot")
        let value = try JSONDecoder().decode(AudioMixerUISnapshot.self, from: bytes)
        guard value.error == nil, value.apps.count == 1, let app = value.apps.first,
            app.objectID == 41, app.pid == 900, app.bundleID == "org.example.synthetic.audio",
            app.normalizedVolume == 0.375
        else { throw HostedFunctionalActionError.invalid }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value.apps)
    }

    func readPersistentState(context: HostedFunctionalActionContext) async throws -> Data? {
        guard context == transport.context else { throw HostedFunctionalActionError.invalid }
        return nil
    }

    func shutdownPresentation() async {
        model.viewDisappeared()
        model.stop()
        client.invalidate()
    }
}
