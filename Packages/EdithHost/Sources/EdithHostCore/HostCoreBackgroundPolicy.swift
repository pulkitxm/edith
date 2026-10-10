import EdithExtensionSupport
import Foundation

public struct HostCoreBackgroundPolicy: Codable, Equatable, Sendable {
    public static let preferenceKey = "agentPauseAmbientOnBattery"
    public let processIdentifier: Int32
    public let pauseAmbientOnBattery: Bool
}

@MainActor public final class HostCoreBackgroundPolicyControl {
    private let defaults: UserDefaults
    private let processIdentifier: @MainActor () -> Int32?
    private let refresh: @MainActor () async throws -> Int32
    private let changed: @MainActor () -> Void

    public init(
        defaults: UserDefaults,
        processIdentifier: @escaping @MainActor () -> Int32?,
        refresh: @escaping @MainActor () async throws -> Int32,
        changed: @escaping @MainActor () -> Void
    ) {
        self.defaults = defaults; self.processIdentifier = processIdentifier
        self.refresh = refresh; self.changed = changed
    }

    public func read() async throws -> HostCoreBackgroundPolicy {
        let pid = try await checkedProcess()
        return HostCoreBackgroundPolicy(
            processIdentifier: pid,
            pauseAmbientOnBattery: defaults.bool(forKey: HostCoreBackgroundPolicy.preferenceKey))
    }

    public func set(pauseAmbientOnBattery: Bool) async throws -> HostCoreBackgroundPolicy {
        let pid = try await checkedProcess()
        defaults.set(pauseAmbientOnBattery, forKey: HostCoreBackgroundPolicy.preferenceKey)
        defaults.synchronize()
        changed()
        return HostCoreBackgroundPolicy(
            processIdentifier: pid, pauseAmbientOnBattery: pauseAmbientOnBattery)
    }

    private func checkedProcess() async throws -> Int32 {
        try Task.checkCancellation()
        guard let pid = processIdentifier(), let identity = ExtensionProcessIdentity.read(pid),
            identity.isAlive
        else { throw HostCoreCommandFailure("The owned core process is offline.") }
        let refreshed = try await refresh()
        try Task.checkCancellation()
        guard refreshed == pid, processIdentifier() == pid,
            ExtensionProcessIdentity.read(pid) == identity, identity.isAlive
        else { throw HostCoreCommandFailure("The core process changed during the command.") }
        return pid
    }
}
