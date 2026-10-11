import EdithExtensionSupport
import Foundation
import FunctionalActionContract

@testable import AppMaintenanceExtension

@MainActor
final class AppMaintenanceActionCase: HostedFunctionalActionCase {
    static let owner = "appMaintenance"
    static let activationOperation = "maintenance.ui.preferences"
    private let transport: HostedFunctionalActionTransport
    private let client: ExtensionEngineClient
    private let model: AppMaintenanceModel

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
        model = AppMaintenanceModel(engineClient: client)
    }

    func activateOriginalControl(context: HostedFunctionalActionContext) async throws {
        guard context == transport.context else { throw HostedFunctionalActionError.invalid }
        try await transport.requireCurrent()
        await model.refreshRemote()
        guard model.errorMessage == nil else { throw HostedFunctionalActionError.invalid }
        for destination in ["system", "user"] {
            let before = transport.originalInvocationCount
            model.updatePreferences { $0.installDestination = destination }
            try await transport.waitForOriginalInvocation(Self.activationOperation, after: before)
            await Task.yield()
        }

    }

    func readAuthoritativeState(context: HostedFunctionalActionContext) async throws -> Data {
        guard context == transport.context else { throw HostedFunctionalActionError.invalid }
        try await transport.requireCurrent()
        let bytes = try await transport.readAuthoritative("maintenance.ui.settings.read")
        let settings = try JSONDecoder().decode(MaintenanceUISettings.self, from: bytes)
        guard settings.installDestination == "user" else {
            throw HostedFunctionalActionError.invalid
        }
        return try JSONSerialization.data(
            withJSONObject: ["installDestination": settings.installDestination],
            options: [.sortedKeys])
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
