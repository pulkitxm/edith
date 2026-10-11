import EdithExtensionSupport
import Foundation
import FunctionalActionContract

@testable import SystemStatsExtension

@MainActor
final class SystemStatsActionCase: HostedFunctionalActionCase {
    static let owner = "systemStats"
    static let activationOperation = "systemStats.ui.update"
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
        let rows = SystemStatsRows(presentation: presentation)
        var binding = rows.modeBinding
        for mode in ["auto", "custom"] {
            guard SharedDefaults.store.string(forKey: AppStorageKeys.MenuBar.statsColorMode) != mode
            else { continue }
            let before = transport.originalInvocationCount
            binding.wrappedValue = mode
            try await transport.waitForOriginalInvocation(Self.activationOperation, after: before)
            await Task.yield()
        }
    }

    func readAuthoritativeState(context: HostedFunctionalActionContext) async throws -> Data {
        guard context == transport.context else { throw HostedFunctionalActionError.invalid }
        try await transport.requireCurrent()
        let bytes = try await transport.readAuthoritative("systemStats.ui.read")
        let packet = try JSONDecoder().decode(ControlPresentationPacket.self, from: bytes)
        let values = try ControlPresentationContract.decode(
            packet.preferences, keys: ControlPresentationContract.readable)
        guard let mode = values[AppStorageKeys.MenuBar.statsColorMode] as? String, mode == "custom"
        else { throw HostedFunctionalActionError.invalid }
        return try JSONSerialization.data(
            withJSONObject: [AppStorageKeys.MenuBar.statsColorMode: mode], options: [.sortedKeys])
    }

    func readPersistentState(context: HostedFunctionalActionContext) async throws -> Data? {
        guard context == transport.context else { throw HostedFunctionalActionError.invalid }
        try await transport.requireCurrent()
        return try await readAuthoritativeState(context: context)
    }

    func shutdownPresentation() async {
        presentation.stop()
    }
}
