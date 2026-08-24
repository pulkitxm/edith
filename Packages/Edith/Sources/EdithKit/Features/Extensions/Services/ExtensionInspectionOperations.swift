import EdithCore
import Foundation

public enum ExtensionInspectionOperation: String, CaseIterable, Sendable {
    case list = "ls"
    case info
    case status
    case verify
    case doctor

    public var descriptor: UserOperationDescriptor {
        let effect: UserOperationEffect = .read
        return switch self {
        case .list:
            UserOperationDescriptor(
                id: UserOperationID(rawValue: "extensions.list"),
                summary: "List registered Edith extensions.",
                cli: ["extensions", "ls"], effect: effect)
        case .info:
            UserOperationDescriptor(
                id: UserOperationID(rawValue: "extensions.info"),
                summary: "Describe an Edith extension.",
                cli: ["extensions", "info"], effect: effect)
        case .status:
            UserOperationDescriptor(
                id: UserOperationID(rawValue: "extensions.status"),
                summary: "Inspect extension readiness.",
                cli: ["extensions", "status"], effect: effect)
        case .verify:
            UserOperationDescriptor(
                id: UserOperationID(rawValue: "extensions.verify"),
                summary: "Run every readiness check for an extension.",
                cli: ["extensions", "verify"], effect: effect)
        case .doctor:
            UserOperationDescriptor(
                id: UserOperationID(rawValue: "extensions.doctor"),
                summary: "Diagnose extension setup and runtime problems.",
                cli: ["extensions", "doctor"], effect: effect)
        }
    }

    public var acceptsOptionalID: Bool {
        self == .status || self == .doctor
    }

    public var requiresID: Bool {
        self == .info || self == .verify
    }
}

public enum ExtensionInspectionError: LocalizedError, Equatable, Sendable {
    case unknownExtension(String, knownIDs: [String])
    case missingExtensionID(ExtensionInspectionOperation)
    case unexpectedExtensionID(ExtensionInspectionOperation)

    public var errorDescription: String? {
        switch self {
        case let .unknownExtension(id, _):
            "no extension named \(id)"
        case let .missingExtensionID(operation):
            "extensions \(operation.rawValue) requires an extension id"
        case let .unexpectedExtensionID(operation):
            "extensions \(operation.rawValue) does not accept an extension id"
        }
    }
}

public struct ExtensionInspectionItem: Equatable, Sendable {
    public let entry: ExtensionRegistryEntry
    public let enabled: Bool
    public let report: ExtensionLifecycleReport?

    public init(
        entry: ExtensionRegistryEntry, enabled: Bool,
        report: ExtensionLifecycleReport? = nil
    ) {
        self.entry = entry
        self.enabled = enabled
        self.report = report
    }
}

public struct ExtensionInspectionResult: Equatable, Sendable {
    public let operation: ExtensionInspectionOperation
    public let items: [ExtensionInspectionItem]

    public init(
        operation: ExtensionInspectionOperation, items: [ExtensionInspectionItem]
    ) {
        self.operation = operation
        self.items = items
    }
}

public struct ExtensionInspectionCenter: Sendable {
    public let entries: [ExtensionRegistryEntry]
    public let isEnabled: @Sendable (ExtensionRegistryEntry) -> Bool
    public let probe: ExtensionLifecycleProbe

    public init(
        entries: [ExtensionRegistryEntry] = ExtensionRegistry.entries,
        isEnabled: @escaping @Sendable (ExtensionRegistryEntry) -> Bool,
        probe: ExtensionLifecycleProbe
    ) {
        self.entries = entries
        self.isEnabled = isEnabled
        self.probe = probe
    }

    public init(
        entries: [ExtensionRegistryEntry] = ExtensionRegistry.entries,
        environment: ExtensionMutationEnvironment
    ) {
        self.init(
            entries: entries,
            isEnabled: { entry in entry.isEnabled(in: environment.defaults) },
            probe: ExtensionLifecycleProbe(environment: environment.lifecycle))
    }

    public func entry(_ id: String) throws -> ExtensionRegistryEntry {
        let needle = id.lowercased()
        if let exact = entries.first(where: { $0.id.lowercased() == needle }) {
            return exact
        }
        if let byKey = entries.first(where: { $0.defaultsKey.lowercased() == needle }) {
            return byKey
        }
        throw ExtensionInspectionError.unknownExtension(id, knownIDs: entries.map(\.id))
    }

    public func list() -> [ExtensionInspectionItem] {
        entries.map(info)
    }

    public func info(_ entry: ExtensionRegistryEntry) -> ExtensionInspectionItem {
        ExtensionInspectionItem(entry: entry, enabled: isEnabled(entry))
    }

    public func execute(
        _ operation: ExtensionInspectionOperation, id: String? = nil
    ) async throws -> ExtensionInspectionResult {
        let selected = try selectedEntries(for: operation, id: id)
        let items = await inspect(selected, operation: operation)
        return ExtensionInspectionResult(
            operation: operation, items: items)
    }

    public func inspect(
        _ entry: ExtensionRegistryEntry, operation: ExtensionInspectionOperation
    ) async -> ExtensionInspectionItem {
        await inspect([entry], operation: operation)[0]
    }

    private func inspect(
        _ selected: [ExtensionRegistryEntry], operation: ExtensionInspectionOperation
    ) async -> [ExtensionInspectionItem] {
        let reports: [ExtensionLifecycleReport?]
        switch operation {
        case .list, .info:
            reports = Array(repeating: nil, count: selected.count)
        case .status, .verify, .doctor:
            reports = await probe.reports(for: selected).map(Optional.some)
        }
        return zip(selected, reports).map { entry, report in
            ExtensionInspectionItem(
                entry: entry, enabled: isEnabled(entry), report: report)
        }
    }

    private func selectedEntries(
        for operation: ExtensionInspectionOperation, id: String?
    ) throws -> [ExtensionRegistryEntry] {
        if operation.requiresID {
            guard let id else { throw ExtensionInspectionError.missingExtensionID(operation) }
            return [try entry(id)]
        }
        if let id {
            guard operation.acceptsOptionalID else {
                throw ExtensionInspectionError.unexpectedExtensionID(operation)
            }
            return [try entry(id)]
        }
        return entries
    }
}
