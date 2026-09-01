import Foundation
import Testing

@testable import EdithDatabase

private enum DatabaseAdapterCapabilitySanitizerFixtures {
    static let secret = "driver-secret-value"
    static let reference = DatabaseSecretReference(
        identifier: UUID(uuidString: "794FCE62-8778-4F90-A5BE-FDF5A33A5231")!,
        purpose: .password)
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static func redactor() async throws -> DatabaseSecretRedactor {
        let store = try InMemoryDatabaseSecretStore(initialValues: [
            reference: Data(secret.utf8)
        ])
        return try await DatabaseSecretRedactor(store: store, references: [reference])
    }

    static func identity(
        modules: [DatabaseExtensionIdentity]? = nil
    ) -> DatabaseProductIdentity {
        DatabaseProductIdentity(
            product: .postgresql,
            version: DatabaseVersion(
                string: "17.4-\(secret)",
                major: 17,
                minor: 4,
                patch: 1),
            distribution: "distribution-\(secret)",
            topology: DatabaseTopology(
                kind: .primaryReplica,
                name: "topology-\(secret)",
                localRole: "primary-\(secret)",
                nodeCount: 3,
                replicaCount: 2,
                shardCount: 1,
                attributes: [
                    DatabaseStringAttribute(
                        name: "topology-name-\(secret)",
                        value: "topology-value-\(secret)")
                ]),
            serverIdentifier: "server-\(secret)",
            modules: modules ?? [
                DatabaseExtensionIdentity(
                    name: "module-\(secret)",
                    version: "1-\(secret)")
            ],
            plugins: [
                DatabaseExtensionIdentity(
                    name: "plugin-\(secret)",
                    version: "2-\(secret)")
            ],
            compatibilityNotes: ["note-\(secret)"])
    }

    static func report(
        identity: DatabaseProductIdentity? = nil,
        capabilities: [DatabaseCapabilityStatus]? = nil,
        permissions: [DatabasePermissionStatus]? = nil,
        pagingModes: [DatabasePagingMode] = [.keyset],
        safetyLimitations: [String]? = nil
    ) -> DatabaseCapabilityReport {
        let reportIdentity = identity ?? self.identity()
        return DatabaseCapabilityReport(
            productIdentity: reportIdentity,
            capabilities: capabilities ?? [capability()],
            permissions: permissions ?? [
                DatabasePermissionStatus(
                    name: "permission-\(secret)",
                    granted: true,
                    scope: "scope-\(secret)")
            ],
            pagingModes: pagingModes,
            mutationModes: [.transactionalBatch],
            transactionModes: [.explicit],
            cancellationModes: [.protocolCancellation],
            importFormats: [.jsonLines],
            exportFormats: [.parquet],
            explainModes: [.analyzed],
            safetyLimitations: safetyLimitations ?? ["limitation-\(secret)"],
            discoveredAt: now,
            expiresAt: now.addingTimeInterval(60))
    }

    static func capability(
        id: DatabaseCapabilityID = .browse,
        attributes: [DatabaseStringAttribute]? = nil,
        missingPermissions: [String]? = nil
    ) -> DatabaseCapabilityStatus {
        DatabaseCapabilityStatus(
            id: id,
            requirement: .sharedRequired,
            availability: .degraded,
            reason: DatabaseCapabilityUnavailableReason(
                category: .permission,
                message: "message-\(secret)",
                requiredVersion: "version-\(secret)",
                requiredTopology: .primaryReplica,
                missingPermissions: missingPermissions ?? ["missing-\(secret)"],
                requiredExtension: "extension-\(secret)",
                constraints: [
                    DatabaseStringAttribute(
                        name: "constraint-name-\(secret)",
                        value: "constraint-value-\(secret)")
                ]),
            limits: [
                DatabaseCapabilityLimit(
                    name: "limit-\(secret)",
                    value: 500,
                    unit: "unit-\(secret)")
            ],
            attributes: attributes ?? [
                DatabaseStringAttribute(
                    name: "attribute-name-\(secret)",
                    value: "attribute-value-\(secret)")
            ])
    }
}

@Suite struct DatabaseAdapterCapabilityReportSanitizerTests {
    @Test func redactsEveryDriverTextSurfaceAndPreservesTypedFields() async throws {
        let report = DatabaseAdapterCapabilitySanitizerFixtures.report()
        let redactor = try await DatabaseAdapterCapabilitySanitizerFixtures.redactor()
        let sanitized = try DatabaseAdapterCapabilityReportSanitizer(
            redactor: redactor
        ).sanitize(report, identity: report.productIdentity)
        let encoded = try JSONEncoder().encode(sanitized)
        let text = String(decoding: encoded, as: UTF8.self)

        #expect(!text.contains(DatabaseAdapterCapabilitySanitizerFixtures.secret))
        #expect(text.contains(DatabaseSecretRedactor.defaultReplacement))
        #expect(sanitized.productIdentity.product == .postgresql)
        #expect(sanitized.productIdentity.version?.major == 17)
        #expect(sanitized.productIdentity.topology.kind == .primaryReplica)
        #expect(sanitized.productIdentity.topology.nodeCount == 3)
        #expect(sanitized.capabilities.first?.id == .browse)
        #expect(sanitized.capabilities.first?.requirement == .sharedRequired)
        #expect(sanitized.capabilities.first?.availability == .degraded)
        #expect(sanitized.capabilities.first?.reason?.category == .permission)
        #expect(sanitized.capabilities.first?.reason?.requiredTopology == .primaryReplica)
        #expect(sanitized.capabilities.first?.limits.first?.value == 500)
        #expect(sanitized.permissions.first?.granted == true)
        #expect(sanitized.discoveredAt == report.discoveredAt)
        #expect(sanitized.expiresAt == report.expiresAt)
    }

    @Test func missingRedactorFailsClosedForDynamicText() throws {
        let report = DatabaseAdapterCapabilitySanitizerFixtures.report()
        let sanitized = try DatabaseAdapterCapabilityReportSanitizer(
            redactor: nil
        ).sanitize(report, identity: report.productIdentity)
        let encoded = try JSONEncoder().encode(sanitized)
        let text = String(decoding: encoded, as: UTF8.self)

        #expect(!text.contains(DatabaseAdapterCapabilitySanitizerFixtures.secret))
        #expect(sanitized.capabilities.first?.id == .browse)
        #expect(sanitized.productIdentity.product == .postgresql)
        #expect(sanitized.productIdentity.topology.nodeCount == 3)
        #expect(sanitized.productIdentity.distribution == DatabaseSecretRedactor.defaultReplacement)
        #expect(
            sanitized.capabilities.first?.reason?.message
                == DatabaseSecretRedactor.defaultReplacement)
    }

    @Test func emptyKnownSecretSetPreservesSafeDynamicMetadata() throws {
        let identifier = DatabaseCapabilityID(rawValue: "custom.replication-status")
        let report = DatabaseAdapterCapabilitySanitizerFixtures.report(
            capabilities: [
                DatabaseAdapterCapabilitySanitizerFixtures.capability(id: identifier)
            ])
        let redactor = try DatabaseSecretRedactor(secrets: [])
        let sanitized = try DatabaseAdapterCapabilityReportSanitizer(
            redactor: redactor
        ).sanitize(report, identity: report.productIdentity)

        #expect(sanitized.capabilities.first?.id == identifier)
        #expect(sanitized.productIdentity.version?.string == "17.4-driver-secret-value")
        #expect(sanitized.productIdentity.distribution == "distribution-driver-secret-value")
        #expect(sanitized.productIdentity.topology.name == "topology-driver-secret-value")
        #expect(sanitized.capabilities.first?.reason?.message == "message-driver-secret-value")
    }

    @Test func rejectsNestedCollectionsPastTheirTypedLimits() {
        let modules = (0...DatabaseAdapterCapabilityReportSanitizer.maximumModules).map {
            DatabaseExtensionIdentity(name: "module-\($0)")
        }
        let moduleIdentity = DatabaseAdapterCapabilitySanitizerFixtures.identity(
            modules: modules)
        let moduleReport = DatabaseAdapterCapabilitySanitizerFixtures.report(
            identity: moduleIdentity)

        #expect(
            throws: DatabaseAdapterFailure.limitExceeded(
                limit: .capabilityModules,
                actual: DatabaseAdapterCapabilityReportSanitizer.maximumModules + 1,
                maximum: DatabaseAdapterCapabilityReportSanitizer.maximumModules)
        ) {
            try DatabaseAdapterCapabilityReportSanitizer(redactor: nil).sanitize(
                moduleReport,
                identity: moduleIdentity)
        }

        let missingPermissions =
            (0...DatabaseAdapterCapabilityReportSanitizer
            .maximumMissingPermissions).map { "permission-\($0)" }
        let reasonReport = DatabaseAdapterCapabilitySanitizerFixtures.report(
            capabilities: [
                DatabaseAdapterCapabilitySanitizerFixtures.capability(
                    missingPermissions: missingPermissions)
            ])

        #expect(
            throws: DatabaseAdapterFailure.limitExceeded(
                limit: .capabilityMissingPermissions,
                actual: DatabaseAdapterCapabilityReportSanitizer.maximumMissingPermissions + 1,
                maximum: DatabaseAdapterCapabilityReportSanitizer.maximumMissingPermissions)
        ) {
            try DatabaseAdapterCapabilityReportSanitizer(redactor: nil).sanitize(
                reasonReport,
                identity: reasonReport.productIdentity)
        }
    }

    @Test func rejectsOversizedStringsAndEncodedReports() {
        let oversizedMessage = String(
            repeating: "x",
            count: DatabaseAdapterCapabilityReportSanitizer.maximumNarrativeStringBytes + 1)
        let stringReport = DatabaseAdapterCapabilitySanitizerFixtures.report(
            safetyLimitations: [oversizedMessage])

        #expect(
            throws: DatabaseAdapterFailure.limitExceeded(
                limit: .capabilityReportStringBytes,
                actual: DatabaseAdapterCapabilityReportSanitizer.maximumNarrativeStringBytes + 1,
                maximum: DatabaseAdapterCapabilityReportSanitizer.maximumNarrativeStringBytes)
        ) {
            try DatabaseAdapterCapabilityReportSanitizer(redactor: nil).sanitize(
                stringReport,
                identity: stringReport.productIdentity)
        }

        let maximumText = String(
            repeating: "x",
            count: DatabaseAdapterCapabilityReportSanitizer.maximumNarrativeStringBytes)
        let byteReport = DatabaseAdapterCapabilitySanitizerFixtures.report(
            safetyLimitations: Array(
                repeating: maximumText,
                count: DatabaseAdapterBounds.maximumSafetyLimitations))

        #expect {
            try DatabaseAdapterCapabilityReportSanitizer(redactor: nil).sanitize(
                byteReport,
                identity: byteReport.productIdentity)
        } throws: { error in
            guard case let DatabaseAdapterFailure.limitExceeded(limit, actual, maximum) = error
            else { return false }
            return limit == .capabilityReportBytes
                && actual > maximum
                && maximum == DatabaseAdapterCapabilityReportSanitizer.maximumEncodedBytes
        }
    }

    @Test func recursivelyBoundsGenericCollectionsAndNodes() {
        let pagingReport = DatabaseAdapterCapabilitySanitizerFixtures.report(
            pagingModes: Array(
                repeating: .offset,
                count: DatabaseAdapterCapabilityReportSanitizer.maximumCollectionElements + 1))

        #expect(
            throws: DatabaseAdapterFailure.limitExceeded(
                limit: .capabilityReportCollectionElements,
                actual: DatabaseAdapterCapabilityReportSanitizer.maximumCollectionElements + 1,
                maximum: DatabaseAdapterCapabilityReportSanitizer.maximumCollectionElements)
        ) {
            try DatabaseAdapterCapabilityReportSanitizer(redactor: nil).sanitize(
                pagingReport,
                identity: pagingReport.productIdentity)
        }

        let attributes = (0..<128).map {
            DatabaseStringAttribute(name: "name-\($0)", value: "value-\($0)")
        }
        let capabilities = (0..<128).map {
            DatabaseAdapterCapabilitySanitizerFixtures.capability(
                id: DatabaseCapabilityID(rawValue: "custom.\($0)"),
                attributes: attributes)
        }
        let nodeReport = DatabaseAdapterCapabilitySanitizerFixtures.report(
            capabilities: capabilities)

        #expect {
            try DatabaseAdapterCapabilityReportSanitizer(redactor: nil).sanitize(
                nodeReport,
                identity: nodeReport.productIdentity)
        } throws: { error in
            guard case let DatabaseAdapterFailure.limitExceeded(limit, actual, maximum) = error
            else { return false }
            return limit == .capabilityReportNodes
                && actual == maximum + 1
                && maximum == DatabaseAdapterCapabilityReportSanitizer.maximumNodes
        }
    }
}

@Suite struct DatabaseResolvedSecretRedactorTests {
    @Test func exactResolvedSecretsAreDeduplicatedOrderedAndRedacted() throws {
        let redactor = try DatabaseSecretRedactor(
            secrets: [
                Data("abc".utf8),
                Data(),
                Data("token-abc".utf8),
                Data("abc".utf8),
            ])

        #expect(
            redactor.redact("token-abc abc")
                == "[REDACTED] [REDACTED]")
    }

    @Test func exactResolvedSecretsEnforceConstructionLimits() {
        #expect(
            throws: DatabaseSecretRedactorError.tooManyReferences(
                actual: DatabaseSecretRedactor.maximumReferences + 1,
                maximum: DatabaseSecretRedactor.maximumReferences)
        ) {
            try DatabaseSecretRedactor(
                secrets: Array(
                    repeating: Data([1]),
                    count: DatabaseSecretRedactor.maximumReferences + 1))
        }

        #expect(
            throws: DatabaseSecretRedactorError.secretMaterialTooLarge(
                actualBytes: DatabaseSecretRedactor.maximumSecretBytes + 1,
                maximumBytes: DatabaseSecretRedactor.maximumSecretBytes)
        ) {
            try DatabaseSecretRedactor(
                secrets: [
                    Data(count: DatabaseSecretRedactor.maximumSecretBytes),
                    Data([1]),
                ])
        }

        #expect(throws: DatabaseSecretRedactorError.invalidReplacement) {
            try DatabaseSecretRedactor(secrets: [], replacement: "")
        }
    }
}
