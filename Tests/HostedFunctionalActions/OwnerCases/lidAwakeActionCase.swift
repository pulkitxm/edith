import EdithExtensionSupport
import Foundation
import FunctionalActionContract

@testable import LidAwakeExtension

@MainActor
final class LidAwakeActionCase: HostedFunctionalActionCase {
    static let owner = "lidAwake"
    static let activationOperation = "lidAwake.battery"
    private let transport: HostedFunctionalActionTransport
    private let model: LidAwakeSettingsModel

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
        model = LidAwakeSettingsModel(client: try transport.makeEngineClient())
    }

    func activateOriginalControl(context: HostedFunctionalActionContext) async throws {
        guard context == transport.context else { throw HostedFunctionalActionError.invalid }
        try await transport.requireCurrent()
        for threshold in [0, 20] {
            let before = transport.originalInvocationCount
            guard let task = model.operations.perform(.setBatteryThreshold(threshold)) else {
                throw HostedFunctionalActionError.invalid
            }
            await task.value
            try await transport.waitForOriginalInvocation(Self.activationOperation, after: before)
            guard model.operations.errorMessage == nil else {
                throw HostedFunctionalActionError.invalid
            }
        }
    }

    func readAuthoritativeState(context: HostedFunctionalActionContext) async throws -> Data {
        guard context == transport.context else { throw HostedFunctionalActionError.invalid }
        try await transport.requireCurrent()
        let bytes = try await transport.readAuthoritative("lidAwake.status")
        let snapshot = try JSONDecoder().decode(LidAwakeSnapshot.self, from: bytes)
        guard snapshot.batteryThreshold == 20, !snapshot.active, !snapshot.requestedActive,
            snapshot.lastError == nil
        else { throw HostedFunctionalActionError.invalid }
        return try JSONSerialization.data(
            withJSONObject: ["batteryThreshold": snapshot.batteryThreshold], options: [.sortedKeys])
    }

    func readPersistentState(context: HostedFunctionalActionContext) async throws -> Data? {
        guard context == transport.context else { throw HostedFunctionalActionError.invalid }
        try await transport.requireCurrent()
        return try await readAuthoritativeState(context: context)
    }

    func shutdownPresentation() async {
        model.stop()
    }
}
