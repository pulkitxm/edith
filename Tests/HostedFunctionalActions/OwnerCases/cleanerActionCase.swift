import EdithExtensionSupport
import Foundation
import FunctionalActionContract

@testable import CleanerExtension

@MainActor
final class CleanerActionCase: HostedFunctionalActionCase {
    static let owner = "cleaner"
    static let activationOperation = "cleaner.ui.action"
    private let transport: HostedFunctionalActionTransport
    private let client: ExtensionEngineClient
    private let model: CleanerModel

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
        model = CleanerModel(engineClient: client, defaults: SharedDefaults.store)
    }

    func activateOriginalControl(context: HostedFunctionalActionContext) async throws {
        guard context == transport.context else { throw HostedFunctionalActionError.invalid }
        try await transport.requireCurrent()
        let path = try context.ownedPath(named: "custom-folder", kind: "directory").path
        guard path.hasPrefix(context.home + "/") else { throw HostedFunctionalActionError.invalid }
        await model.refreshRemote()
        if model.customFolders.contains(path) {
            let before = transport.originalInvocationCount
            model.removeCustomFolder(path)
            try await transport.waitForOriginalInvocation(Self.activationOperation, after: before)
            await Task.yield()
        }
        let before = transport.originalInvocationCount
        model.addCustomFolder(path)
        try await transport.waitForOriginalInvocation(Self.activationOperation, after: before)
    }

    func readAuthoritativeState(context: HostedFunctionalActionContext) async throws -> Data {
        guard context == transport.context else { throw HostedFunctionalActionError.invalid }
        try await transport.requireCurrent()
        let path = try context.ownedPath(named: "custom-folder", kind: "directory").path
        guard path.hasPrefix(context.home + "/") else { throw HostedFunctionalActionError.invalid }
        let bytes = try await transport.readAuthoritative("cleaner.ui.snapshot")
        let snapshot = try JSONDecoder().decode(CleanerUISnapshot.self, from: bytes)
        guard snapshot.customFolders == [path], snapshot.driveSelection?.contains(path) == true,
            !snapshot.scanning
        else { throw HostedFunctionalActionError.invalid }
        return try JSONSerialization.data(
            withJSONObject: ["customFolders": snapshot.customFolders], options: [.sortedKeys])
    }

    func readPersistentState(context: HostedFunctionalActionContext) async throws -> Data? {
        guard context == transport.context else { throw HostedFunctionalActionError.invalid }
        try await transport.requireCurrent()
        return try await readAuthoritativeState(context: context)
    }

    func shutdownPresentation() async {
        await model.shutdown()
        client.invalidate()
    }
}
