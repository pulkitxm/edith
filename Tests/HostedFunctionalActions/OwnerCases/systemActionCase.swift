import EdithExtensionSupport
import Foundation
import FunctionalActionContract

@testable import SystemExtension

@MainActor
final class SystemActionCase: HostedFunctionalActionCase {
    static let owner = "system"
    static let activationOperation = "system.apps.sort"
    private let transport: HostedFunctionalActionTransport
    private let client: ExtensionEngineClient
    private let model: RunningAppsModel
    private let presentation: SystemPresentationState

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
        presentation = SystemPresentationState(channel: nil)
        model = RunningAppsModel(
            engineClient: client, presentation: presentation, defaults: SharedDefaults.store)
    }

    func activateOriginalControl(context: HostedFunctionalActionContext) async throws {
        guard context == transport.context else { throw HostedFunctionalActionError.invalid }
        try await transport.requireCurrent()
        await model.refresh()
        if model.sortKey == .name, model.ascending {
            let before = transport.originalInvocationCount
            model.sort(by: .name)
            try await transport.waitForOriginalInvocation(Self.activationOperation, after: before)
            await Task.yield()
        }
        let before = transport.originalInvocationCount
        model.sort(by: .name)
        try await transport.waitForOriginalInvocation(Self.activationOperation, after: before)
    }

    func readAuthoritativeState(context: HostedFunctionalActionContext) async throws -> Data {
        guard context == transport.context else { throw HostedFunctionalActionError.invalid }
        try await transport.requireCurrent()
        let bytes = try await transport.readAuthoritative("system.apps.snapshot")
        let snapshot = try JSONDecoder().decode(SystemAppsSnapshot.self, from: bytes)
        guard snapshot.sortKey == "name", snapshot.ascending else {
            throw HostedFunctionalActionError.invalid
        }
        return try JSONSerialization.data(
            withJSONObject: ["sortKey": snapshot.sortKey, "ascending": snapshot.ascending],
            options: [.sortedKeys])
    }

    func readPersistentState(context: HostedFunctionalActionContext) async throws -> Data? {
        guard context == transport.context else { throw HostedFunctionalActionError.invalid }
        try await transport.requireCurrent()
        return try await readAuthoritativeState(context: context)
    }

    func shutdownPresentation() async {
        model.shutdown()
        presentation.shutdown()
        client.invalidate()
    }
}
