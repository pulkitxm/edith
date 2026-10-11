import EdithExtensionSupport
import Foundation
import FunctionalActionContract

@testable import BifrostExtension

@MainActor
final class BifrostActionCase: HostedFunctionalActionCase {
    static let owner = "bifrost"
    static let activationOperation = "bifrost.ui.set"
    private let transport: HostedFunctionalActionTransport
    private let model: BifrostUIContext
    private let client: ExtensionEngineClient

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
        guard BifrostUIContext.current == nil else { throw HostedFunctionalActionError.invalid }
        client = try transport.makeEngineClient()
        model = BifrostUIContext(client: client)
        BifrostUIContext.current = model
    }

    func activateOriginalControl(context: HostedFunctionalActionContext) async throws {
        guard context == transport.context else { throw HostedFunctionalActionError.invalid }
        try await transport.requireCurrent()
        await model.load()
        guard model.loaded, model.error == nil else { throw HostedFunctionalActionError.invalid }
        let key = AppStorageKeys.Bifrost.pasteSnippets
        for value in [false, true] {
            guard SharedDefaults.store.bool(forKey: key) != value else { continue }
            let before = transport.originalInvocationCount
            BifrostUIContext.write(key, value: value)
            try await transport.waitForOriginalInvocation(Self.activationOperation, after: before)
            await Task.yield()
        }
    }

    func readAuthoritativeState(context: HostedFunctionalActionContext) async throws -> Data {
        guard context == transport.context else { throw HostedFunctionalActionError.invalid }
        try await transport.requireCurrent()
        let bytes = try await transport.readAuthoritative("bifrost.ui.settings")
        let settings = try JSONDecoder().decode(BifrostUISettings.self, from: bytes)
        let key = AppStorageKeys.Bifrost.pasteSnippets
        guard let value = settings.values[key], value == "true" else {
            throw HostedFunctionalActionError.invalid
        }
        return try JSONSerialization.data(withJSONObject: [key: value], options: [.sortedKeys])
    }

    func readPersistentState(context: HostedFunctionalActionContext) async throws -> Data? {
        guard context == transport.context else { throw HostedFunctionalActionError.invalid }
        try await transport.requireCurrent()
        return try await readAuthoritativeState(context: context)
    }

    func shutdownPresentation() async {
        model.shutdown()
        if BifrostUIContext.current === model { BifrostUIContext.current = nil }
        client.invalidate()
    }
}
