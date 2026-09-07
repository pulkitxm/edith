import EdithDatabase
import Foundation
import Testing

@Suite struct DatabaseIdentityTests {
    @Test func everyProductHasTheExpectedFamily() {
        #expect(DatabaseProduct.postgresql.family == .relational)
        #expect(DatabaseProduct.mysql.family == .relational)
        #expect(DatabaseProduct.mariaDB.family == .relational)
        #expect(DatabaseProduct.sqlite.family == .relational)
        #expect(DatabaseProduct.redis.family == .keyValue)
        #expect(DatabaseProduct.valkey.family == .keyValue)
        #expect(DatabaseProduct.mongoDB.family == .document)
        #expect(DatabaseProduct.elasticsearch.family == .search)
        #expect(DatabaseProduct.openSearch.family == .search)
        #expect(DatabaseProduct.clickHouse.family == .analytical)
    }

    @Test func productIdentityRoundTripsWithoutDuplicatingFamily() throws {
        let identity = DatabaseProductIdentity(
            product: .openSearch,
            version: DatabaseVersion(string: "3.2.0", major: 3, minor: 2, patch: 0),
            distribution: "OpenSearch",
            topology: DatabaseTopology(
                kind: .cluster,
                name: "search",
                localRole: "cluster_manager",
                nodeCount: 3,
                replicaCount: 1,
                shardCount: 12),
            serverIdentifier: "node-1",
            modules: [DatabaseExtensionIdentity(name: "analysis-icu", version: "3.2.0")],
            plugins: [DatabaseExtensionIdentity(name: "sql", version: "3.2.0")],
            compatibilityNotes: ["PIT is enabled"])

        let decoded = try modelRoundTrip(identity)

        #expect(decoded == identity)
        #expect(decoded.family == .search)
    }
}

@Suite struct DatabaseConnectionDefinitionTests {
    @Test func completeDefinitionRoundTripsThroughJSON() throws {
        let definition = try DatabaseConnectionFixtures.connectionDefinition()
        let decoded = try modelRoundTrip(definition)

        #expect(decoded == definition)
        #expect(decoded.identity == DatabaseConnectionFixtures.connectionIdentity)
        #expect(decoded.tags == ["orders", "critical"])
        #expect(decoded.tunnel?.machineIdentifier == "tuf-wired")
    }

    @Test func encodedAuthenticationContainsOnlyTypedReferences() throws {
        let definition = try DatabaseConnectionFixtures.connectionDefinition()
        let data = try JSONEncoder().encode(definition)
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let authentication = try #require(root["authentication"] as? [String: Any])
        let references = try #require(authentication["secretReferences"] as? [[String: Any]])

        #expect(Set(authentication.keys) == ["kind", "secretReferences"])
        #expect(Set(try #require(references.first).keys) == ["identifier", "purpose"])
    }

    @Test func sqliteLocationRoundTripsWithAFileReference() throws {
        let location = DatabaseConnectionLocation.sqlite(
            DatabaseSQLiteLocation(
                path: "/tmp/orders.sqlite",
                accessMode: .readOnly,
                fileReference: DatabaseResourceReference(
                    identifier: UUID(uuidString: "46436872-AF15-455B-8537-037B718DB4D2")!,
                    kind: .sqliteBookmark)))

        #expect(try modelRoundTrip(location) == location)
    }

    @Test func connectionBoundsRejectInvalidConstruction() {
        #expect(throws: DatabaseBoundedValueError.port(0)) {
            try DatabasePort(0)
        }
        #expect(throws: DatabaseBoundedValueError.port(65_536)) {
            try DatabasePort(65_536)
        }
        #expect(throws: DatabaseBoundedValueError.timeoutMilliseconds(99)) {
            try DatabaseTimeout(milliseconds: 99)
        }
        #expect(throws: DatabaseBoundedValueError.poolSize(257)) {
            try DatabasePoolSize(257)
        }
    }

    @Test func connectionBoundsRejectInvalidJSON() {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(DatabasePort.self, from: Data("0".utf8))
        }
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(DatabaseTimeout.self, from: Data("99".utf8))
        }
    }
}

@Suite struct DatabaseCapabilityTests {
    @Test func unavailableReasonAndReportRoundTrip() throws {
        let identity = DatabaseProductIdentity(
            product: .mongoDB,
            version: DatabaseVersion(string: "8.0.0", major: 8, minor: 0, patch: 0),
            topology: DatabaseTopology(kind: .standalone))
        let reason = DatabaseCapabilityUnavailableReason(
            category: .topology,
            message: "Transactions require a replica set or sharded cluster.",
            requiredTopology: .replicaSet,
            constraints: [DatabaseStringAttribute(name: "wireVersion", value: "25")])
        let status = DatabaseCapabilityStatus(
            id: .transactions,
            requirement: .productRequired,
            availability: .unavailable,
            reason: reason)
        let report = DatabaseCapabilityReport(
            productIdentity: identity,
            capabilities: [
                status,
                DatabaseCapabilityStatus(
                    id: .browse,
                    requirement: .sharedRequired,
                    availability: .available),
            ],
            pagingModes: [.serverCursor],
            mutationModes: [.singleRecord, .boundedBatch],
            transactionModes: [.none],
            cancellationModes: [.protocolCancellation],
            importFormats: [.json, .jsonLines],
            exportFormats: [.json, .jsonLines],
            discoveredAt: Date(timeIntervalSince1970: 1_700_000_000))

        let decoded = try modelRoundTrip(report)

        #expect(decoded == report)
        #expect(decoded.supports(.browse))
        #expect(!decoded.supports(.transactions))
        #expect(decoded.unavailableReason(for: .transactions) == reason)
    }
}
