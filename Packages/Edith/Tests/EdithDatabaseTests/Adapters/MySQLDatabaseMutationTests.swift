import Foundation
import Testing

@testable import EdithDatabase

private enum MySQLDatabaseMutationFixtures {
    static func identity(
        product: DatabaseProduct,
        readOnly: Bool = false
    ) -> DatabaseProductIdentity {
        DatabaseProductIdentity(
            product: product,
            version: product == .mariaDB
                ? DatabaseVersion(string: "11.8.3-MariaDB", major: 11, minor: 8, patch: 3)
                : DatabaseVersion(string: "8.4.6", major: 8, minor: 4, patch: 6),
            distribution: product.displayName,
            topology: DatabaseTopology(
                kind: product == .mariaDB ? .unknown : .standalone,
                localRole: readOnly ? "read-only" : (product == .mysql ? "primary" : nil),
                nodeCount: product == .mysql ? 1 : nil,
                attributes: [
                    DatabaseStringAttribute(name: "readOnly", value: String(readOnly)),
                    DatabaseStringAttribute(name: "superReadOnly", value: String(readOnly)),
                ]),
            serverIdentifier: product == .mariaDB ? "7" : "mysql-fixture")
    }

    static func writableDefinition(
        product: DatabaseProduct
    ) throws -> DatabaseConnectionDefinition {
        try MySQLDatabaseFoundationFixtures.definition(
            product: product,
            readOnlyPolicy: .disabled,
            productionPolicy: .standard,
            environmentProtection: .standard)
    }

    static func target(
        connectionID: DatabaseConnectionID,
        objectPath: [String] = ["edith_lab", "orders"],
        identityKind: DatabaseRecordIdentityKind? = .primaryKey,
        identityValue: DatabaseValue = .signedInteger(42)
    ) -> DatabaseTargetIdentifier {
        DatabaseTargetIdentifier(
            connectionID: connectionID,
            object: DatabaseObjectIdentifier(kind: .table, path: objectPath),
            record: identityKind.map { kind in
                DatabaseRecordIdentity(
                    kind: kind,
                    components: [
                        DatabaseIdentityComponent(name: "id", value: identityValue)
                    ])
            })
    }
}

private actor MySQLDatabaseMutationTestClient: MySQLDatabaseClient {
    private let identity: DatabaseProductIdentity
    private var mutationResults: [MySQLDatabaseMutationResult]
    private var mutationPlans: [MySQLDatabaseMutationPlan] = []

    init(
        identity: DatabaseProductIdentity,
        mutationResults: [MySQLDatabaseMutationResult] = []
    ) {
        self.identity = identity
        self.mutationResults = mutationResults
    }

    func discoverIdentity() -> DatabaseProductIdentity {
        identity
    }

    func executeMutation(
        _ plan: MySQLDatabaseMutationPlan
    ) throws -> MySQLDatabaseMutationResult {
        mutationPlans.append(plan)
        guard !mutationResults.isEmpty else {
            throw MySQLDatabaseDriverFailure.invalidRequest
        }
        return mutationResults.removeFirst()
    }

    func disconnect() {}

    func capturedMutationPlans() -> [MySQLDatabaseMutationPlan] {
        mutationPlans
    }
}

@Test func mysqlMutationRequestsBuildCanonicalBoundCRUDForBothProducts() throws {
    for product in [DatabaseProduct.mysql, .mariaDB] {
        let connectionID = DatabaseConnectionID()
        let insertTarget = MySQLDatabaseMutationFixtures.target(
            connectionID: connectionID,
            objectPath: ["edith_lab", "order`items"],
            identityKind: nil)
        let insert = try DatabaseRowMutationRequests.mySQLInsert(
            target: insertTarget,
            product: product,
            values: [
                DatabaseObjectField(name: "id", value: .signedInteger(42)),
                DatabaseObjectField(name: "display`name", value: .string("new'); DROP TABLE x")),
            ])
        #expect(insert.payload.product == product)
        #expect(
            insert.payload.command
                == "INSERT INTO `edith_lab`.`order``items` (`id`, `display``name`) VALUES (?, ?)")
        #expect(
            insert.payload.parameters.map(\.value) == [
                .signedInteger(42), .string("new'); DROP TABLE x"),
            ])

        let rowTarget = MySQLDatabaseMutationFixtures.target(
            connectionID: connectionID,
            objectPath: ["edith_lab", "order`items"])
        let update = try DatabaseRowMutationRequests.mySQLUpdate(
            target: rowTarget,
            product: product,
            values: [DatabaseObjectField(name: "status", value: .string("paid"))])
        #expect(
            update.payload.command
                == "UPDATE `edith_lab`.`order``items` SET `status` = ? WHERE `id` <=> ? LIMIT 1")
        #expect(update.payload.parameters.map(\.value) == [.string("paid")])

        let delete = try DatabaseRowMutationRequests.mySQLDelete(
            target: rowTarget,
            product: product)
        #expect(
            delete.payload.command
                == "DELETE FROM `edith_lab`.`order``items` WHERE `id` <=> ? LIMIT 1")
        #expect(delete.payload.parameters.isEmpty)
    }
}

@Test func mysqlMutationRequestsRequireSafeUniqueIdentity() throws {
    let connectionID = DatabaseConnectionID()
    let uniqueTarget = MySQLDatabaseMutationFixtures.target(
        connectionID: connectionID,
        identityKind: .uniqueKey,
        identityValue: .string("order-42"))
    let uniqueDelete = try DatabaseRowMutationRequests.mySQLDelete(
        target: uniqueTarget,
        product: .mysql)
    #expect(uniqueDelete.payload.command.contains("WHERE `id` <=> ? LIMIT 1"))

    let ambiguousTarget = MySQLDatabaseMutationFixtures.target(
        connectionID: connectionID,
        identityKind: .explicitPredicate)
    #expect(throws: DatabaseRowMutationRequestError.unsupportedIdentity) {
        try DatabaseRowMutationRequests.mySQLDelete(
            target: ambiguousTarget,
            product: .mysql)
    }

    let nullableTarget = MySQLDatabaseMutationFixtures.target(
        connectionID: connectionID,
        identityKind: .uniqueKey,
        identityValue: .null)
    #expect(throws: DatabaseRowMutationRequestError.unsupportedIdentity) {
        try DatabaseRowMutationRequests.mySQLDelete(
            target: nullableTarget,
            product: .mariaDB)
    }

    let rowTarget = MySQLDatabaseMutationFixtures.target(connectionID: connectionID)
    #expect(throws: DatabaseRowMutationRequestError.unsupportedIdentity) {
        try DatabaseRowMutationRequests.mySQLUpdate(
            target: rowTarget,
            product: .mysql,
            values: [DatabaseObjectField(name: "id", value: .signedInteger(99))])
    }
    #expect(throws: DatabaseRowMutationRequestError.invalidTarget) {
        try DatabaseRowMutationRequests.mySQLDelete(
            target: rowTarget,
            product: .postgresql)
    }
}

@Test func mysqlAdapterNormalizesAndExecutesBoundUpdatesForBothProducts() async throws {
    for product in [DatabaseProduct.mysql, .mariaDB] {
        let definition = try MySQLDatabaseMutationFixtures.writableDefinition(product: product)
        let client = MySQLDatabaseMutationTestClient(
            identity: MySQLDatabaseMutationFixtures.identity(product: product),
            mutationResults: [MySQLDatabaseMutationResult(affectedRows: 1)])
        let session = MySQLDatabaseAdapterSession(
            connection: definition,
            productIdentity: MySQLDatabaseMutationFixtures.identity(product: product),
            client: client)
        let context = MySQLDatabaseFoundationFixtures.context()
        let report = try await session.discoverCapabilities(context: context)
        #expect(report.status(for: .insert)?.availability == .available)
        #expect(report.status(for: .update)?.availability == .available)
        #expect(report.status(for: .delete)?.availability == .available)
        #expect(report.mutationModes == [.singleRecord])
        #expect(report.transactionModes == [.implicit])

        let request = try DatabaseRowMutationRequests.mySQLUpdate(
            target: MySQLDatabaseMutationFixtures.target(connectionID: definition.id),
            product: product,
            values: [DatabaseObjectField(name: "status", value: .string("paid"))])
        let plan = try await session.normalizeMutation(request, context: context)
        #expect(plan.action == .update)
        #expect(plan.scope == .singleRecord)
        #expect(plan.impact.count == DatabaseCountMetadata(value: 1, accuracy: .exact))
        #expect(plan.transactionBehavior == .productDependent)
        #expect(plan.rollbackAvailability == .conditional)
        #expect(plan.warnings.map(\.code) == ["mysql.mutation.storage_engine"])

        let result = try await session.executeMutation(plan, context: context)
        #expect(result.disposition == .completed)
        #expect(result.effect == .applied)
        #expect(result.affectedRecords == DatabaseCountMetadata(value: 1, accuracy: .exact))
        let executed = try #require((await client.capturedMutationPlans()).first)
        #expect(executed.sql == request.payload.command)
        #expect(executed.parameters == [.string("paid"), .signedInteger(42)])
        #expect(executed.binds == [.string("paid"), .signedInteger(42)])
        await session.disconnect()
    }
}

@Test func mysqlAdapterReportsStaleRowsWithoutApplyingMutation() async throws {
    let definition = try MySQLDatabaseMutationFixtures.writableDefinition(product: .mysql)
    let identity = MySQLDatabaseMutationFixtures.identity(product: .mysql)
    let client = MySQLDatabaseMutationTestClient(
        identity: identity,
        mutationResults: [MySQLDatabaseMutationResult(affectedRows: 0)])
    let session = MySQLDatabaseAdapterSession(
        connection: definition,
        productIdentity: identity,
        client: client)
    let request = try DatabaseRowMutationRequests.mySQLDelete(
        target: MySQLDatabaseMutationFixtures.target(connectionID: definition.id),
        product: .mysql)
    let plan = try await session.normalizeMutation(
        request,
        context: MySQLDatabaseFoundationFixtures.context())
    let result = try await session.executeMutation(
        plan,
        context: MySQLDatabaseFoundationFixtures.context())

    #expect(result.effect == .notApplied)
    #expect(result.affectedRecords == DatabaseCountMetadata(value: 0, accuracy: .exact))
    #expect(result.error?.category == .conflict)
    #expect(result.error?.productCode == "mysql.mutation.row_not_found")
}

@Test func mysqlAdapterRejectsNoncanonicalMutationStatements() async throws {
    let definition = try MySQLDatabaseMutationFixtures.writableDefinition(product: .mysql)
    let identity = MySQLDatabaseMutationFixtures.identity(product: .mysql)
    let session = MySQLDatabaseAdapterSession(
        connection: definition,
        productIdentity: identity,
        client: MySQLDatabaseMutationTestClient(identity: identity))
    let canonical = try DatabaseRowMutationRequests.mySQLUpdate(
        target: MySQLDatabaseMutationFixtures.target(connectionID: definition.id),
        product: .mysql,
        values: [DatabaseObjectField(name: "status", value: .string("unsafe"))])
    let forged = DatabaseDestructiveRequest(
        target: canonical.target,
        payload: .relational(
            product: .mysql,
            statement: "UPDATE orders SET status = 'unsafe'",
            parameters: canonical.payload.parameters))

    await #expect(throws: MySQLDatabaseAdapterSupport.invalidMutation) {
        _ = try await session.normalizeMutation(
            forged,
            context: MySQLDatabaseFoundationFixtures.context())
    }
}

@Test func mysqlAdapterGatesMutationCapabilitiesByPolicyAndTopology() throws {
    let policyDefinition = try MySQLDatabaseFoundationFixtures.definition(product: .mysql)
    let policyReport = MySQLDatabaseAdapterSupport.capabilityReport(
        identity: MySQLDatabaseMutationFixtures.identity(product: .mysql),
        connection: policyDefinition)
    #expect(policyReport.status(for: .update)?.availability == .unavailable)
    #expect(policyReport.unavailableReason(for: .update)?.category == .connectionPolicy)
    #expect(policyReport.mutationModes.isEmpty)

    let topologyDefinition = try MySQLDatabaseMutationFixtures.writableDefinition(
        product: .mariaDB)
    let topologyReport = MySQLDatabaseAdapterSupport.capabilityReport(
        identity: MySQLDatabaseMutationFixtures.identity(product: .mariaDB, readOnly: true),
        connection: topologyDefinition)
    #expect(topologyReport.status(for: .delete)?.availability == .unavailable)
    #expect(topologyReport.unavailableReason(for: .delete)?.category == .topology)
    #expect(topologyReport.mutationModes.isEmpty)
    #expect(topologyReport.safetyLimitations == ["The connected server reports read-only mode."])
}
