import Foundation

public enum PlatformCapability: String, CaseIterable, Codable, Hashable, Sendable {
    case applicationAudio
    case bluetoothMonitoring
    case calendarEvents
    case cameraPreview
    case clipboardHistory
    case companionService
    case externalMediaControl
    case fileShelf
    case globalPaste
    case herdrSessions
    case globalShortcuts
    case inputSuppression
    case localMusicPlayback
    case machineManagement
    case mediaControls
    case microphoneControl
    case notifications
    case preventSleep
    case runningApplications
    case screenColorSampling
    case screenShareDetection
    case systemMetrics
    case usageCollection
    case windowDimming
}

public enum PlatformCapabilityState: Equatable, Sendable {
    case available
    case permissionRequired
    case integrationRequired(String)
    case unsupported(String)

    public var isSupported: Bool {
        switch self {
        case .available, .permissionRequired:
            true
        case .integrationRequired, .unsupported:
            false
        }
    }
}

public enum ExtensionPlatformAvailability: Equatable, Sendable {
    case available
    case degraded([PlatformCapability])
    case unavailable([PlatformCapability])
}

public struct PlatformCapabilities: Equatable, Sendable {
    public let states: [PlatformCapability: PlatformCapabilityState]

    public init(states: [PlatformCapability: PlatformCapabilityState]) {
        self.states = states
    }

    public func state(for capability: PlatformCapability) -> PlatformCapabilityState {
        states[capability] ?? .unsupported("Capability has no platform implementation.")
    }

    public func availability(
        required: [PlatformCapability], optional: [PlatformCapability]
    ) -> ExtensionPlatformAvailability {
        let missingRequired = required.filter { !state(for: $0).isSupported }
        if !missingRequired.isEmpty { return .unavailable(missingRequired) }
        let missingOptional = optional.filter { !state(for: $0).isSupported }
        if !missingOptional.isEmpty { return .degraded(missingOptional) }
        return .available
    }

    public static let macOS = PlatformCapabilities(
        states: states(
            defaultState: .available,
            overriding: [
                .bluetoothMonitoring: .permissionRequired,
                .calendarEvents: .permissionRequired,
                .cameraPreview: .permissionRequired,
                .globalPaste: .permissionRequired,
                .inputSuppression: .permissionRequired,
                .notifications: .permissionRequired,
                .screenColorSampling: .permissionRequired,
                .screenShareDetection: .permissionRequired,
                .windowDimming: .permissionRequired,
            ]))

    private static func states(
        defaultState: PlatformCapabilityState,
        overriding overrides: [PlatformCapability: PlatformCapabilityState]
    ) -> [PlatformCapability: PlatformCapabilityState] {
        var states = Dictionary(
            uniqueKeysWithValues: PlatformCapability.allCases.map {
                ($0, defaultState)
            })
        for (capability, state) in overrides { states[capability] = state }
        return states
    }
}
