import Foundation

struct DatabaseAdapterCapabilityReportSanitizer: Sendable {
    static let maximumEncodedBytes = 1_048_576
    static let maximumNodes = 32_768
    static let maximumCollectionElements = 512
    static let maximumDepth = 16
    static let maximumIdentifierBytes = 256
    static let maximumMetadataStringBytes = 4_096
    static let maximumNarrativeStringBytes = 16_384
    static let maximumModules = 128
    static let maximumPlugins = 128
    static let maximumCompatibilityNotes = 128
    static let maximumTopologyAttributes = 256
    static let maximumMissingPermissions = 256
    static let maximumReasonConstraints = 256
    static let maximumCapabilityLimits = 128
    static let maximumCapabilityAttributes = 256

    private static let stableCapabilityIdentifiers: Set<DatabaseCapabilityID> = [
        .connectionTest,
        .objectDiscovery,
        .objectDescription,
        .query,
        .queryCancellation,
        .explain,
        .browse,
        .insert,
        .update,
        .delete,
        .bulkMutation,
        .importData,
        .exportData,
        .transactions,
        .schemaMutation,
        .monitoring,
        .administration,
    ]

    private let redactor: DatabaseSecretRedactor?

    init(redactor: DatabaseSecretRedactor?) {
        self.redactor = redactor
    }

    func sanitize(
        _ report: DatabaseCapabilityReport,
        identity: DatabaseProductIdentity
    ) throws(DatabaseAdapterFailure) -> DatabaseCapabilityReport {
        try Self.validate(report, identity: identity)
        let productIdentity = try sanitize(report.productIdentity)
        let capabilities = try sanitizeValues(report.capabilities) {
            try sanitize($0)
        }
        let permissions = try sanitizeValues(report.permissions) {
            try sanitize($0)
        }
        let safetyLimitations = try sanitizeValues(report.safetyLimitations) {
            try sanitizeText($0, maximumBytes: Self.maximumNarrativeStringBytes)
        }
        let sanitized = DatabaseCapabilityReport(
            productIdentity: productIdentity,
            capabilities: capabilities,
            permissions: permissions,
            pagingModes: report.pagingModes,
            mutationModes: report.mutationModes,
            transactionModes: report.transactionModes,
            cancellationModes: report.cancellationModes,
            importFormats: report.importFormats,
            exportFormats: report.exportFormats,
            explainModes: report.explainModes,
            safetyLimitations: safetyLimitations,
            discoveredAt: report.discoveredAt,
            expiresAt: report.expiresAt)
        try Self.validateStructure(sanitized)
        return sanitized
    }

    static func validate(
        _ report: DatabaseCapabilityReport,
        identity: DatabaseProductIdentity
    ) throws(DatabaseAdapterFailure) {
        guard report.productIdentity == identity else {
            throw .contractViolation(.capabilityIdentityMismatch)
        }
        try validateStructure(report)
    }

    private static func validateStructure(
        _ report: DatabaseCapabilityReport
    ) throws(DatabaseAdapterFailure) {
        try require(
            report.capabilities.count,
            atMost: DatabaseAdapterBounds.maximumCapabilities,
            limit: .capabilities)
        try require(
            report.permissions.count,
            atMost: DatabaseAdapterBounds.maximumPermissions,
            limit: .permissions)
        try require(
            report.safetyLimitations.count,
            atMost: DatabaseAdapterBounds.maximumSafetyLimitations,
            limit: .safetyLimitations)
        try require(
            report.productIdentity.modules.count,
            atMost: maximumModules,
            limit: .capabilityModules)
        try require(
            report.productIdentity.plugins.count,
            atMost: maximumPlugins,
            limit: .capabilityPlugins)
        try require(
            report.productIdentity.compatibilityNotes.count,
            atMost: maximumCompatibilityNotes,
            limit: .capabilityCompatibilityNotes)
        try require(
            report.productIdentity.topology.attributes.count,
            atMost: maximumTopologyAttributes,
            limit: .capabilityTopologyAttributes)

        var identifiers = Set<DatabaseCapabilityID>()
        for capability in report.capabilities {
            guard identifiers.insert(capability.id).inserted else {
                throw .contractViolation(.duplicateCapability(capability.id))
            }
            try require(
                capability.limits.count,
                atMost: maximumCapabilityLimits,
                limit: .capabilityLimits)
            try require(
                capability.attributes.count,
                atMost: maximumCapabilityAttributes,
                limit: .capabilityAttributes)
            if let reason = capability.reason {
                try require(
                    reason.missingPermissions.count,
                    atMost: maximumMissingPermissions,
                    limit: .capabilityMissingPermissions)
                try require(
                    reason.constraints.count,
                    atMost: maximumReasonConstraints,
                    limit: .capabilityReasonConstraints)
            }
        }

        try validateTypedStrings(report)
        try validateEncodedStructure(report)
    }

    private static func validateTypedStrings(
        _ report: DatabaseCapabilityReport
    ) throws(DatabaseAdapterFailure) {
        let identity = report.productIdentity
        try validateText(identity.version?.string, maximumBytes: maximumMetadataStringBytes)
        try validateText(identity.distribution, maximumBytes: maximumMetadataStringBytes)
        try validateText(identity.serverIdentifier, maximumBytes: maximumMetadataStringBytes)
        try validateText(identity.topology.name, maximumBytes: maximumMetadataStringBytes)
        try validateText(identity.topology.localRole, maximumBytes: maximumMetadataStringBytes)
        for attribute in identity.topology.attributes {
            try validateAttribute(attribute)
        }
        for module in identity.modules {
            try validateExtension(module)
        }
        for plugin in identity.plugins {
            try validateExtension(plugin)
        }
        for note in identity.compatibilityNotes {
            try validateText(note, maximumBytes: maximumNarrativeStringBytes)
        }

        for capability in report.capabilities {
            try validateText(capability.id.rawValue, maximumBytes: maximumIdentifierBytes)
            for attribute in capability.attributes {
                try validateAttribute(attribute)
            }
            for limit in capability.limits {
                try validateText(limit.name, maximumBytes: maximumIdentifierBytes)
                try validateText(limit.unit, maximumBytes: maximumMetadataStringBytes)
            }
            if let reason = capability.reason {
                try validateText(reason.message, maximumBytes: maximumNarrativeStringBytes)
                try validateText(
                    reason.requiredVersion,
                    maximumBytes: maximumMetadataStringBytes)
                try validateText(
                    reason.requiredExtension,
                    maximumBytes: maximumMetadataStringBytes)
                for permission in reason.missingPermissions {
                    try validateText(permission, maximumBytes: maximumMetadataStringBytes)
                }
                for constraint in reason.constraints {
                    try validateAttribute(constraint)
                }
            }
        }

        for permission in report.permissions {
            try validateText(permission.name, maximumBytes: maximumMetadataStringBytes)
            try validateText(permission.scope, maximumBytes: maximumMetadataStringBytes)
        }
        for limitation in report.safetyLimitations {
            try validateText(limitation, maximumBytes: maximumNarrativeStringBytes)
        }
    }

    private static func validateExtension(
        _ value: DatabaseExtensionIdentity
    ) throws(DatabaseAdapterFailure) {
        try validateText(value.name, maximumBytes: maximumMetadataStringBytes)
        try validateText(value.version, maximumBytes: maximumMetadataStringBytes)
    }

    private static func validateAttribute(
        _ value: DatabaseStringAttribute
    ) throws(DatabaseAdapterFailure) {
        try validateText(value.name, maximumBytes: maximumIdentifierBytes)
        try validateText(value.value, maximumBytes: maximumMetadataStringBytes)
    }

    private static func validateText(
        _ value: String?,
        maximumBytes: Int
    ) throws(DatabaseAdapterFailure) {
        guard let value else { return }
        try require(
            value.utf8.count,
            atMost: maximumBytes,
            limit: .capabilityReportStringBytes)
    }

    private static func validateEncodedStructure(
        _ report: DatabaseCapabilityReport
    ) throws(DatabaseAdapterFailure) {
        let data: Data
        do {
            data = try JSONEncoder().encode(report)
        } catch {
            throw .contractViolation(.encodingFailed)
        }
        try require(
            data.count,
            atMost: maximumEncodedBytes,
            limit: .capabilityReportBytes)

        let value: Any
        do {
            value = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw .contractViolation(.encodingFailed)
        }
        var nodeCount = 0
        try validateJSONNode(value, depth: 0, nodeCount: &nodeCount)
    }

    private static func validateJSONNode(
        _ value: Any,
        depth: Int,
        nodeCount: inout Int
    ) throws(DatabaseAdapterFailure) {
        try require(depth, atMost: maximumDepth, limit: .capabilityReportDepth)
        nodeCount += 1
        try require(
            nodeCount,
            atMost: maximumNodes,
            limit: .capabilityReportNodes)

        if let object = value as? [String: Any] {
            try require(
                object.count,
                atMost: maximumCollectionElements,
                limit: .capabilityReportCollectionElements)
            for (key, nestedValue) in object {
                try validateText(key, maximumBytes: maximumIdentifierBytes)
                try validateJSONNode(
                    nestedValue,
                    depth: depth + 1,
                    nodeCount: &nodeCount)
            }
        } else if let array = value as? [Any] {
            try require(
                array.count,
                atMost: maximumCollectionElements,
                limit: .capabilityReportCollectionElements)
            for nestedValue in array {
                try validateJSONNode(
                    nestedValue,
                    depth: depth + 1,
                    nodeCount: &nodeCount)
            }
        } else if let string = value as? String {
            try validateText(string, maximumBytes: maximumNarrativeStringBytes)
        }
    }

    private static func require(
        _ actual: Int,
        atMost maximum: Int,
        limit: DatabaseAdapterLimit
    ) throws(DatabaseAdapterFailure) {
        guard actual <= maximum else {
            throw .limitExceeded(limit: limit, actual: actual, maximum: maximum)
        }
    }

    private func sanitize(
        _ identity: DatabaseProductIdentity
    ) throws(DatabaseAdapterFailure) -> DatabaseProductIdentity {
        let version = try sanitizeOptional(identity.version) {
            DatabaseVersion(
                string: try sanitizeText(
                    $0.string,
                    maximumBytes: Self.maximumMetadataStringBytes),
                major: $0.major,
                minor: $0.minor,
                patch: $0.patch)
        }
        let modules = try sanitizeValues(identity.modules) {
            try sanitize($0)
        }
        let plugins = try sanitizeValues(identity.plugins) {
            try sanitize($0)
        }
        let compatibilityNotes = try sanitizeValues(identity.compatibilityNotes) {
            try sanitizeText($0, maximumBytes: Self.maximumNarrativeStringBytes)
        }
        return DatabaseProductIdentity(
            product: identity.product,
            version: version,
            distribution: try sanitizeOptionalText(
                identity.distribution,
                maximumBytes: Self.maximumMetadataStringBytes),
            topology: try sanitize(identity.topology),
            serverIdentifier: try sanitizeOptionalText(
                identity.serverIdentifier,
                maximumBytes: Self.maximumMetadataStringBytes),
            modules: modules,
            plugins: plugins,
            compatibilityNotes: compatibilityNotes)
    }

    private func sanitize(
        _ topology: DatabaseTopology
    ) throws(DatabaseAdapterFailure) -> DatabaseTopology {
        let attributes = try sanitizeValues(topology.attributes) {
            try sanitize($0)
        }
        return DatabaseTopology(
            kind: topology.kind,
            name: try sanitizeOptionalText(
                topology.name,
                maximumBytes: Self.maximumMetadataStringBytes),
            localRole: try sanitizeOptionalText(
                topology.localRole,
                maximumBytes: Self.maximumMetadataStringBytes),
            nodeCount: topology.nodeCount,
            replicaCount: topology.replicaCount,
            shardCount: topology.shardCount,
            attributes: attributes)
    }

    private func sanitize(
        _ value: DatabaseExtensionIdentity
    ) throws(DatabaseAdapterFailure) -> DatabaseExtensionIdentity {
        DatabaseExtensionIdentity(
            name: try sanitizeText(
                value.name,
                maximumBytes: Self.maximumMetadataStringBytes),
            version: try sanitizeOptionalText(
                value.version,
                maximumBytes: Self.maximumMetadataStringBytes))
    }

    private func sanitize(
        _ capability: DatabaseCapabilityStatus
    ) throws(DatabaseAdapterFailure) -> DatabaseCapabilityStatus {
        let reason = try sanitizeOptional(capability.reason) {
            try sanitize($0)
        }
        let limits = try sanitizeValues(capability.limits) {
            try sanitize($0)
        }
        let attributes = try sanitizeValues(capability.attributes) {
            try sanitize($0)
        }
        return DatabaseCapabilityStatus(
            id: try sanitize(capability.id),
            requirement: capability.requirement,
            availability: capability.availability,
            reason: reason,
            limits: limits,
            attributes: attributes)
    }

    private func sanitize(
        _ identifier: DatabaseCapabilityID
    ) throws(DatabaseAdapterFailure) -> DatabaseCapabilityID {
        if redactor == nil, Self.stableCapabilityIdentifiers.contains(identifier) {
            return identifier
        }
        return DatabaseCapabilityID(
            rawValue: try sanitizeText(
                identifier.rawValue,
                maximumBytes: Self.maximumIdentifierBytes))
    }

    private func sanitize(
        _ reason: DatabaseCapabilityUnavailableReason
    ) throws(DatabaseAdapterFailure) -> DatabaseCapabilityUnavailableReason {
        let missingPermissions = try sanitizeValues(reason.missingPermissions) {
            try sanitizeText($0, maximumBytes: Self.maximumMetadataStringBytes)
        }
        let constraints = try sanitizeValues(reason.constraints) {
            try sanitize($0)
        }
        return DatabaseCapabilityUnavailableReason(
            category: reason.category,
            message: try sanitizeText(
                reason.message,
                maximumBytes: Self.maximumNarrativeStringBytes),
            requiredVersion: try sanitizeOptionalText(
                reason.requiredVersion,
                maximumBytes: Self.maximumMetadataStringBytes),
            requiredTopology: reason.requiredTopology,
            missingPermissions: missingPermissions,
            requiredExtension: try sanitizeOptionalText(
                reason.requiredExtension,
                maximumBytes: Self.maximumMetadataStringBytes),
            constraints: constraints)
    }

    private func sanitize(
        _ value: DatabaseCapabilityLimit
    ) throws(DatabaseAdapterFailure) -> DatabaseCapabilityLimit {
        DatabaseCapabilityLimit(
            name: try sanitizeText(
                value.name,
                maximumBytes: Self.maximumIdentifierBytes),
            value: value.value,
            unit: try sanitizeOptionalText(
                value.unit,
                maximumBytes: Self.maximumMetadataStringBytes))
    }

    private func sanitize(
        _ value: DatabaseStringAttribute
    ) throws(DatabaseAdapterFailure) -> DatabaseStringAttribute {
        DatabaseStringAttribute(
            name: try sanitizeText(
                value.name,
                maximumBytes: Self.maximumIdentifierBytes),
            value: try sanitizeText(
                value.value,
                maximumBytes: Self.maximumMetadataStringBytes))
    }

    private func sanitize(
        _ permission: DatabasePermissionStatus
    ) throws(DatabaseAdapterFailure) -> DatabasePermissionStatus {
        DatabasePermissionStatus(
            name: try sanitizeText(
                permission.name,
                maximumBytes: Self.maximumMetadataStringBytes),
            granted: permission.granted,
            scope: try sanitizeOptionalText(
                permission.scope,
                maximumBytes: Self.maximumMetadataStringBytes))
    }

    private func sanitizeOptionalText(
        _ value: String?,
        maximumBytes: Int
    ) throws(DatabaseAdapterFailure) -> String? {
        guard let value else { return nil }
        return try sanitizeText(value, maximumBytes: maximumBytes)
    }

    private func sanitizeText(
        _ value: String,
        maximumBytes: Int
    ) throws(DatabaseAdapterFailure) -> String {
        try Self.validateText(value, maximumBytes: maximumBytes)
        guard !value.isEmpty else { return value }
        guard let redactor else { return DatabaseSecretRedactor.defaultReplacement }
        let sanitized = redactor.redact(value)
        try Self.validateText(sanitized, maximumBytes: maximumBytes)
        return sanitized
    }

    private func sanitizeValues<Input, Output>(
        _ values: [Input],
        transform: (Input) throws -> Output
    ) throws(DatabaseAdapterFailure) -> [Output] {
        var sanitized: [Output] = []
        sanitized.reserveCapacity(values.count)
        do {
            for value in values {
                sanitized.append(try transform(value))
            }
        } catch let failure as DatabaseAdapterFailure {
            throw failure
        } catch {
            throw .contractViolation(.encodingFailed)
        }
        return sanitized
    }

    private func sanitizeOptional<Input, Output>(
        _ value: Input?,
        transform: (Input) throws -> Output
    ) throws(DatabaseAdapterFailure) -> Output? {
        guard let value else { return nil }
        do {
            return try transform(value)
        } catch let failure as DatabaseAdapterFailure {
            throw failure
        } catch {
            throw .contractViolation(.encodingFailed)
        }
    }
}
