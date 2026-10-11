import EdithExtensionSupport
import Foundation
import FunctionalActionContract

@testable import JevExtension

@MainActor
final class JevActionCase: HostedFunctionalActionCase {
    static let owner = "jev"
    static let activationOperation = "jev.key.set"
    private let transport: HostedFunctionalActionTransport
    private let client: ExtensionEngineClient
    private let model: JevSettingsModel

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
        client = try transport.makeEngineClient()
        model = JevSettingsModel(engineClient: client)
    }

    func activateOriginalControl(context: HostedFunctionalActionContext) async throws {
        guard context == transport.context else { throw HostedFunctionalActionError.invalid }
        try await transport.requireCurrent()
        let before = transport.originalInvocationCount
        model.draft = "synthetic-functional-" + context.session
        model.save()
        try await transport.waitForOriginalInvocation(Self.activationOperation, after: before)
    }

    func readAuthoritativeState(context: HostedFunctionalActionContext) async throws -> Data {
        guard context == transport.context else { throw HostedFunctionalActionError.invalid }
        try await transport.requireCurrent()
        let payload = try JSONEncoder().encode(JevStatusQuery(probe: false))
        let bytes = try await transport.readAuthoritative("jev.status", payload: payload)
        let status = try JSONDecoder().decode(JevStatus.self, from: bytes)
        guard status.state == .ready, let hint = status.keyHint,
            hint == "ending " + context.session.suffix(4)
        else { throw HostedFunctionalActionError.invalid }
        return try JSONSerialization.data(
            withJSONObject: ["state": status.state.rawValue, "keyHint": hint],
            options: [.sortedKeys])
    }

    func readPersistentState(context: HostedFunctionalActionContext) async throws -> Data? {
        guard context == transport.context else { throw HostedFunctionalActionError.invalid }
        try await transport.requireCurrent()
        return try await readAuthoritativeState(context: context)
    }

    func shutdownPresentation() async {
        model.shutdown()
        client.invalidate()
    }
}
