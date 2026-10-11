import EdithExtensionSupport
import Foundation
import FunctionalActionContract

@testable import CodeStatsExtension

@MainActor
final class CodeStatsActionCase: HostedFunctionalActionCase {
    static let owner = "codeStats"
    static let activationOperation = "codeStats.ui.folder"
    private let transport: HostedFunctionalActionTransport
    private let model: CodeStatsModel

    init(transport: HostedFunctionalActionTransport) throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["HOME"] == transport.context.home,
            environment["CFFIXED_USER_HOME"] == transport.context.home,
            environment["EDITH_EXTENSION_DATA_ROOT"] == transport.context.dataDirectory,
            environment["EDITH_SHARED_DEFAULTS_SUITE"] == transport.context.hostIdentifier + ".functional.ui." + Self.owner + "." + transport.context.phase
        else { throw HostedFunctionalActionError.invalid }
        let context = transport.context
        guard context.owner == Self.owner,
            let defaults = UserDefaults(suiteName: context.hostIdentifier + ".functional.ui.codeStats." + context.phase)
        else { throw HostedFunctionalActionError.invalid }
        self.transport = transport
        let bridge = CodeStatsUIBridge { operation, payload in
            try await transport.invokeOriginal(operation, payload: payload)
        }
        model = CodeStatsModel(service: bridge.service, remote: bridge, defaults: defaults)
    }

    func activateOriginalControl(context: HostedFunctionalActionContext) async throws {
        guard context == transport.context else { throw HostedFunctionalActionError.invalid }
        let retained = try context.ownedPath(named: "repository-folder", kind: "directory")
        let temporary = try context.ownedPath(named: "temporary-repository-folder", kind: "directory")
        guard retained != temporary else { throw HostedFunctionalActionError.invalid }
        let baseline = try await readState(context: context, folder: retained)
        var count = transport.originalInvocationCount
        await model.chooseFolder(temporary.path)
        try await transport.waitForOriginalInvocation(Self.activationOperation, after: count)
        guard model.errorMessage == nil else { throw HostedFunctionalActionError.invalid }
        let changed = try await readState(context: context, folder: temporary)
        guard changed != baseline else { throw HostedFunctionalActionError.invalid }
        count = transport.originalInvocationCount
        await model.chooseFolder(retained.path)
        try await transport.waitForOriginalInvocation(Self.activationOperation, after: count)
        guard model.errorMessage == nil,
            try await readState(context: context, folder: retained) == baseline
        else { throw HostedFunctionalActionError.invalid }
    }

    func readAuthoritativeState(context: HostedFunctionalActionContext) async throws -> Data {
        try await readState(context: context, folder: try context.ownedPath(named: "repository-folder", kind: "directory"))
    }

    private func readState(context: HostedFunctionalActionContext, folder: URL) async throws -> Data {
        guard context == transport.context else { throw HostedFunctionalActionError.invalid }
        let bytes = try await transport.readAuthoritative("codeStats.ui.status")
        let value = try JSONDecoder().decode(CodeStatsStatus.self, from: bytes)
        guard value.settings.folder == folder.path else { throw HostedFunctionalActionError.invalid }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value.settings)
    }

    func readPersistentState(context: HostedFunctionalActionContext) async throws -> Data? {
        try await readAuthoritativeState(context: context)
    }

    func shutdownPresentation() async { model.cancelLoading() }
}
