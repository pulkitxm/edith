import Foundation

extension PlatformCapability {
    public var title: String {
        var words = ""
        for character in rawValue {
            if character.isUppercase && !words.isEmpty {
                words.append(" ")
                words.append(Character(character.lowercased()))
            } else {
                words.append(character)
            }
        }
        return words.prefix(1).uppercased() + words.dropFirst()
    }
}

extension PlatformCapabilityState {
    public var summary: String {
        switch self {
        case .available: "Available"
        case .permissionRequired: "Needs permission"
        case let .integrationRequired(detail): "Needs \(detail)"
        case let .unsupported(detail): detail
        }
    }
}

extension ExtensionPlatformAvailability {
    public var summary: String {
        switch self {
        case .available: "Available"
        case .degraded: "Partly available"
        case .unavailable: "Not available yet"
        }
    }

    public var missingCapabilities: [PlatformCapability] {
        switch self {
        case .available: []
        case let .degraded(capabilities): capabilities
        case let .unavailable(capabilities): capabilities
        }
    }
}

public struct ExtensionAvailabilityReport: Sendable {
    public let entry: ExtensionRegistryEntry
    public let availability: ExtensionPlatformAvailability
    public let blockers: [(capability: PlatformCapability, state: PlatformCapabilityState)]

    public init(entry: ExtensionRegistryEntry, capabilities: PlatformCapabilities) {
        self.entry = entry
        let availability = entry.availability(on: capabilities)
        self.availability = availability
        self.blockers = availability.missingCapabilities.map {
            ($0, capabilities.state(for: $0))
        }
    }

    public var detail: String {
        guard let first = blockers.first else { return entry.subtitle }
        if blockers.count == 1 { return "\(first.capability.title): \(first.state.summary)" }
        return "\(first.capability.title) and \(blockers.count - 1) more still need work"
    }

    public static func reports(
        for capabilities: PlatformCapabilities
    ) -> [ExtensionAvailabilityReport] {
        ExtensionRegistry.entries.map {
            ExtensionAvailabilityReport(entry: $0, capabilities: capabilities)
        }
    }
}
