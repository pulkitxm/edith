import EdithExtensionSupport
import Foundation
import FunctionalActionContract

@testable import HomebrewExtension

@MainActor
final class HomebrewActionCase: HostedFunctionalActionCase {
    static let owner = "homebrew"
    static let activationOperation = "homebrew.preference.write"
    private let transport: HostedFunctionalActionTransport
    private let client: ExtensionEngineClient
    private let model: HomebrewPageModel

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
        model = HomebrewPageModel(engineClient: client)
    }

    func activateOriginalControl(context: HostedFunctionalActionContext) async throws {
        guard context == transport.context else { throw HostedFunctionalActionError.invalid }
        try await transport.requireCurrent()
        if try await model.preferredKind() == .cask {
            let before = transport.originalInvocationCount
            model.savePreferredKind(.formula)
            try await transport.waitForOriginalInvocation(Self.activationOperation, after: before)
            await Task.yield()
        }
        let before = transport.originalInvocationCount
        model.savePreferredKind(.cask)
        try await transport.waitForOriginalInvocation(Self.activationOperation, after: before)
    }

    func readAuthoritativeState(context: HostedFunctionalActionContext) async throws -> Data {
        guard context == transport.context else { throw HostedFunctionalActionError.invalid }
        try await transport.requireCurrent()
        let bytes = try await transport.readAuthoritative("homebrew.preference.read")
        guard try JSONDecoder().decode(HomebrewPackageKind.self, from: bytes) == .cask else {
            throw HostedFunctionalActionError.invalid
        }
        return bytes
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
