import Foundation
import Testing

@testable import EdithDatabase

private enum DatabaseExecutionContractFixtures {
    static let deadline = Date(timeIntervalSince1970: 1_800_000_000)
    static let testedAt = Date(timeIntervalSince1970: 1_799_999_900)
    static let operationID = DatabaseOperationID(
        rawValue: UUID(uuidString: "7A7F612D-6F68-42A4-BA5A-70EAB1A75D49")!)

    static var operation: DatabaseOperationContext {
        DatabaseOperationContext(operationID: operationID, deadline: deadline)
    }

    static var target: DatabaseTargetIdentifier {
        DatabaseTargetIdentifier(
            connectionID: DatabaseConnectionFixtures.connectionID,
            object: DatabaseOperationFixtures.object)
    }

    static var productIdentity: DatabaseProductIdentity {
        DatabaseProductIdentity(
            product: .postgresql,
            version: DatabaseVersion(string: "17.4", major: 17, minor: 4, patch: 0),
            distribution: "PostgreSQL",
            topology: DatabaseTopology(
                kind: .primaryReplica,
                name: "orders",
                localRole: "primary",
                nodeCount: 2,
                replicaCount: 1),
            serverIdentifier: "orders-primary",
            modules: [DatabaseExtensionIdentity(name: "pg_stat_statements", version: "1.11")],
            compatibilityNotes: ["standard conforming strings enabled"])
    }

    static var capabilityReport: DatabaseCapabilityReport {
        DatabaseCapabilityReport(
            productIdentity: productIdentity,
            capabilities: [
                DatabaseCapabilityStatus(
                    id: .browse,
                    requirement: .sharedRequired,
                    availability: .available,
                    limits: [DatabaseCapabilityLimit(name: "pageSize", value: 2_000)]),
                DatabaseCapabilityStatus(
                    id: .queryCancellation,
                    requirement: .sharedRequired,
                    availability: .degraded,
                    reason: DatabaseCapabilityUnavailableReason(
                        category: .permission,
                        message: "Cancellation is limited to the current account.")),
            ],
            permissions: [DatabasePermissionStatus(name: "SELECT", granted: true)],
            pagingModes: [.keyset, .serverCursor],
            mutationModes: [.singleRecord, .transactionalBatch],
            transactionModes: [.explicit, .savepoints],
            cancellationModes: [.protocolCancellation],
            importFormats: [.csv, .jsonLines],
            exportFormats: [.csv, .jsonLines],
            explainModes: [.logical, .analyzed],
            safetyLimitations: ["Production mutations require confirmation."],
            discoveredAt: testedAt,
            expiresAt: deadline)
    }

    static var page: DatabasePage<DatabaseRecord> {
        DatabasePage(
            records: [
                DatabaseRecord(
                    identity: DatabaseRecordIdentity(
                        kind: .primaryKey,
                        components: [
                            DatabaseIdentityComponent(name: "id", value: .signedInteger(42))
                        ]),
                    fields: [
                        DatabaseObjectField(name: "id", value: .signedInteger(42)),
                        DatabaseObjectField(name: "total", value: .decimal("125.50")),
                        DatabaseObjectField(name: "note", value: .null),
                    ])
            ],
            fields: [
                DatabaseFieldDescriptor(
                    path: DatabaseFieldPath("id"),
                    displayName: "id",
                    typeName: "int8",
                    isNullable: false,
                    isSortable: true,
                    isFilterable: true),
                DatabaseFieldDescriptor(
                    path: DatabaseFieldPath("total"),
                    displayName: "total",
                    typeName: "numeric",
                    isNullable: false,
                    isSortable: true,
                    isFilterable: true),
            ],
            nextContinuation: DatabaseContinuationToken(rawValue: "next-page"),
            metadata: DatabasePageMetadata(
                completeness: DatabaseResultCompleteness(state: .complete),
                count: DatabaseCountMetadata(value: 1, accuracy: .exact),
                timing: DatabaseQueryTiming(
                    durationMilliseconds: 12,
                    serverDurationMilliseconds: 9),
                bytesReceived: 512))
    }

    static var mutation: DatabaseDestructiveRequest {
        DatabaseDestructiveRequest(
            target: target,
            predicate: .predicate(
                DatabaseFilterPredicate(
                    field: DatabaseFieldPath("state"),
                    operation: .equal,
                    values: [.string("pending")])),
            payload: .relational(
                product: .postgresql,
                statement: "UPDATE invoices SET state = $1 WHERE state = $2",
                parameters: [
                    DatabaseMutationParameter(name: "next", value: .string("paid")),
                    DatabaseMutationParameter(name: "current", value: .string("pending")),
                ]))
    }

    static var destructivePreview: DatabaseDestructivePreview {
        let impact = DatabaseMutationImpact(
            count: DatabaseCountMetadata(value: 12, accuracy: .estimated),
            description: "About 12 invoices")
        let warning = DatabaseWarning(
            code: "production",
            message: "This changes production data.",
            severity: .high,
            target: target)
        let effect = DatabaseDestructiveEffect(
            action: .updateMany,
            connection: DatabaseConnectionFixtures.connectionIdentity,
            context: DatabaseMutationContext(
                kind: .database,
                value: "orders",
                schema: "public"),
            target: target,
            selectedRecords: [],
            predicate: mutation.predicate,
            scope: .predicate,
            impact: impact,
            transactionBehavior: .transactional,
            rollbackAvailability: .available,
            executionMode: .synchronous,
            executionDigest: "execution-digest",
            displayDigest: "display-digest")
        let request = DatabaseMutationPreview(
            product: .postgresql,
            kind: .sql,
            command: "UPDATE invoices SET state = $1 WHERE state = $2",
            parameters: [
                DatabaseMutationParameterPreview(name: "next", valueKind: .string),
                DatabaseMutationParameterPreview(name: "current", valueKind: .string),
            ],
            body: nil)
        return DatabaseDestructivePreview(
            effect: effect,
            request: request,
            warnings: [warning],
            requiredConfirmation: DatabaseRequiredConfirmation(
                strength: .connectionAndTarget,
                text: "Orders invoices"),
            issuedAt: testedAt,
            expiresAt: deadline,
            token: DatabaseConfirmationToken(rawValue: "payload.signature"))
    }

    static func roundTrip<Value>(_ value: Value) throws -> Value
    where Value: Codable & Equatable {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let data = try encoder.encode(value)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(Value.self, from: data)
    }
}

@Suite struct DatabaseExecutionContractsTests {
    @Test func connectAndDisconnectContractsPreserveOperationCorrelation() throws {
        let request = DatabaseConnectRequest(
            connectionID: DatabaseConnectionFixtures.connectionID,
            operation: DatabaseExecutionContractFixtures.operation)
        let decodedRequest = try DatabaseExecutionContractFixtures.roundTrip(request)

        #expect(decodedRequest == request)
        #expect(decodedRequest.version == DatabaseConnectRequest.schemaVersion)
        #expect(decodedRequest.operation == DatabaseExecutionContractFixtures.operation)

        let connectResult = DatabaseConnectResult(
            connection: DatabaseConnectionFixtures.connectionIdentity,
            productIdentity: DatabaseExecutionContractFixtures.productIdentity,
            capabilities: DatabaseExecutionContractFixtures.capabilityReport,
            connectedAt: DatabaseExecutionContractFixtures.testedAt)
        #expect(try DatabaseExecutionContractFixtures.roundTrip(connectResult) == connectResult)

        let disconnectRequest = DatabaseDisconnectRequest(
            connectionID: DatabaseConnectionFixtures.connectionID,
            operation: DatabaseExecutionContractFixtures.operation)
        #expect(
            try DatabaseExecutionContractFixtures.roundTrip(disconnectRequest)
                == disconnectRequest)

        let disconnectResult = DatabaseDisconnectResult(
            connection: DatabaseConnectionFixtures.connectionIdentity,
            disconnected: true,
            disconnectedAt: DatabaseExecutionContractFixtures.testedAt)
        #expect(
            try DatabaseExecutionContractFixtures.roundTrip(disconnectResult)
                == disconnectResult)
    }

    @Test func connectionTestContractsPreserveOperationCorrelation() throws {
        let definition = try DatabaseConnectionFixtures.connectionDefinition()
        let request = DatabaseConnectionTestRequest(
            connection: definition,
            operation: DatabaseExecutionContractFixtures.operation)
        let decodedRequest = try DatabaseExecutionContractFixtures.roundTrip(request)

        #expect(decodedRequest == request)
        #expect(decodedRequest.version == DatabaseConnectionTestRequest.schemaVersion)
        #expect(
            decodedRequest.operation.operationID == DatabaseExecutionContractFixtures.operationID)
        #expect(decodedRequest.operation.deadline == DatabaseExecutionContractFixtures.deadline)
        #expect(decodedRequest.connection == definition)

        let result = DatabaseConnectionTestResult(
            connection: definition.identity,
            productIdentity: DatabaseExecutionContractFixtures.productIdentity,
            capabilities: DatabaseExecutionContractFixtures.capabilityReport,
            latencyMilliseconds: 18,
            testedAt: DatabaseExecutionContractFixtures.testedAt)

        #expect(try DatabaseExecutionContractFixtures.roundTrip(result) == result)
    }

    @Test func capabilityContractsPreserveResolutionAndReportSource() throws {
        let request = DatabaseCapabilitiesRequest(
            connectionID: DatabaseConnectionFixtures.connectionID,
            resolution: .refresh,
            operation: DatabaseExecutionContractFixtures.operation)
        let decodedRequest = try DatabaseExecutionContractFixtures.roundTrip(request)

        #expect(decodedRequest == request)
        #expect(decodedRequest.resolution == .refresh)
        #expect(decodedRequest.operation == DatabaseExecutionContractFixtures.operation)

        let result = DatabaseCapabilitiesResult(
            report: DatabaseExecutionContractFixtures.capabilityReport,
            source: .discovered)
        let decodedResult = try DatabaseExecutionContractFixtures.roundTrip(result)

        #expect(decodedResult == result)
        #expect(decodedResult.source == .discovered)
        #expect(decodedResult.report.supports(.browse))
        #expect(decodedResult.report.status(for: .queryCancellation)?.availability == .degraded)
    }

    @Test func browseContractsPreserveTargetBoundsAndContinuation() throws {
        let pageRequest = DatabasePageRequest(
            pageSize: try DatabasePageSize(125),
            projection: DatabaseProjection(
                mode: .include,
                fields: [
                    DatabaseProjectedField(path: DatabaseFieldPath("id")),
                    DatabaseProjectedField(path: DatabaseFieldPath("total")),
                ]),
            filter: .predicate(
                DatabaseFilterPredicate(
                    field: DatabaseFieldPath("total"),
                    operation: .greaterThan,
                    values: [.decimal("100.00")])),
            sorts: [
                DatabaseSort(
                    field: DatabaseFieldPath("id"),
                    direction: .ascending,
                    nullPlacement: .productDefault)
            ],
            consistency: .snapshot)
        let request = DatabaseBrowseRequest(
            target: DatabaseExecutionContractFixtures.target,
            page: pageRequest,
            operation: DatabaseExecutionContractFixtures.operation)
        let decodedRequest = try DatabaseExecutionContractFixtures.roundTrip(request)

        #expect(decodedRequest == request)
        #expect(decodedRequest.target == DatabaseExecutionContractFixtures.target)
        #expect(decodedRequest.page.pageSize.value == 125)
        #expect(
            decodedRequest.operation.operationID == DatabaseExecutionContractFixtures.operationID)

        let result = DatabaseBrowseResult(page: DatabaseExecutionContractFixtures.page)
        let decodedResult = try DatabaseExecutionContractFixtures.roundTrip(result)

        #expect(decodedResult == result)
        #expect(decodedResult.page.records.count == 1)
        #expect(decodedResult.page.nextContinuation?.rawValue == "next-page")
    }

    @Test func queryContractsRequireOneTargetAndPreserveTypedInputs() throws {
        let body = DatabaseValue.object([
            DatabaseObjectField(
                name: "filter",
                value: .object([
                    DatabaseObjectField(name: "active", value: .boolean(true)),
                    DatabaseObjectField(name: "deletedAt", value: .missing),
                ])),
            DatabaseObjectField(
                name: "projection",
                value: .array([.string("id"), .string("total")])),
        ])
        let parameters = [
            DatabaseQueryParameter(
                name: "tenant",
                value: .uuid(
                    UUID(uuidString: "D5C93A7B-D924-47B2-BDEE-065671050F92")!)),
            DatabaseQueryParameter(value: .signedInteger(25)),
            DatabaseQueryParameter(
                name: "digest",
                value: .binary(
                    .complete(
                        data: Data([0, 1, 2, 3]),
                        mediaType: "application/octet-stream",
                        digest: "sha256:010203"))),
        ]
        let request = DatabaseQueryRequest(
            target: DatabaseExecutionContractFixtures.target,
            language: .mongoQuery,
            command: "find",
            parameters: parameters,
            body: body,
            page: DatabasePageRequest(pageSize: try DatabasePageSize(100)),
            operation: DatabaseExecutionContractFixtures.operation)
        let decodedRequest = try DatabaseExecutionContractFixtures.roundTrip(request)

        #expect(decodedRequest == request)
        #expect(decodedRequest.target == DatabaseExecutionContractFixtures.target)
        #expect(decodedRequest.target.connectionID == DatabaseConnectionFixtures.connectionID)
        #expect(decodedRequest.language == .mongoQuery)
        #expect(decodedRequest.parameters == parameters)
        #expect(decodedRequest.body == body)
        #expect(decodedRequest.operation.deadline == DatabaseExecutionContractFixtures.deadline)

        let result = DatabaseQueryResult(page: DatabaseExecutionContractFixtures.page)
        #expect(try DatabaseExecutionContractFixtures.roundTrip(result) == result)
    }

    @Test func mutationPreviewContractsPreserveTheCanonicalRequestAndPreview() throws {
        let request = DatabaseMutationPreviewRequest(
            mutation: DatabaseExecutionContractFixtures.mutation,
            operation: DatabaseExecutionContractFixtures.operation)
        let decodedRequest = try DatabaseExecutionContractFixtures.roundTrip(request)

        #expect(decodedRequest == request)
        #expect(decodedRequest.mutation == DatabaseExecutionContractFixtures.mutation)
        #expect(
            decodedRequest.operation.operationID == DatabaseExecutionContractFixtures.operationID)

        let result = DatabaseMutationPreviewResult(
            preview: DatabaseExecutionContractFixtures.destructivePreview)
        let decodedResult = try DatabaseExecutionContractFixtures.roundTrip(result)

        #expect(decodedResult == result)
        #expect(
            decodedResult.preview.effect.context
                == DatabaseMutationContext(
                    kind: .database,
                    value: "orders",
                    schema: "public"))
        #expect(decodedResult.preview.effect.executionDigest == "execution-digest")
        #expect(decodedResult.preview.effect.displayDigest == "display-digest")
        #expect(decodedResult.preview.token.rawValue == "payload.signature")
    }

    @Test func mutationApplyContractsRepeatExactAuthorizationInputsAndOutcome() throws {
        let token = DatabaseConfirmationToken(rawValue: "signed.payload")
        let confirmationText = "Orders invoices"
        let request = DatabaseMutationApplyRequest(
            mutation: DatabaseExecutionContractFixtures.mutation,
            token: token,
            confirmationText: confirmationText,
            operation: DatabaseExecutionContractFixtures.operation)
        let decodedRequest = try DatabaseExecutionContractFixtures.roundTrip(request)

        #expect(decodedRequest == request)
        #expect(decodedRequest.mutation == DatabaseExecutionContractFixtures.mutation)
        #expect(decodedRequest.token == token)
        #expect(decodedRequest.confirmationText == confirmationText)
        #expect(decodedRequest.operation == DatabaseExecutionContractFixtures.operation)

        let result = DatabaseMutationApplyResult(
            disposition: .accepted,
            affectedRecords: DatabaseCountMetadata(value: 12, accuracy: .estimated),
            returnedRecords: DatabaseExecutionContractFixtures.page,
            serverOperationIdentifier: "server-task-42")
        let decodedResult = try DatabaseExecutionContractFixtures.roundTrip(result)

        #expect(decodedResult == result)
        #expect(decodedResult.disposition == .accepted)
        #expect(decodedResult.affectedRecords.value == 12)
        #expect(decodedResult.returnedRecords?.records.count == 1)
        #expect(decodedResult.serverOperationIdentifier == "server-task-42")
    }

    @Test func mutationReconciliationContractsPreserveServerAndClientCorrelation() throws {
        let serverOperationIdentifier = "server-task-42"
        let statusRequest = DatabaseMutationStatusRequest(
            connectionID: DatabaseConnectionFixtures.connectionID,
            serverOperationIdentifier: serverOperationIdentifier,
            operation: DatabaseExecutionContractFixtures.operation)
        #expect(try DatabaseExecutionContractFixtures.roundTrip(statusRequest) == statusRequest)

        let returnedRecords = DatabasePage(
            records: DatabaseExecutionContractFixtures.page.records,
            fields: DatabaseExecutionContractFixtures.page.fields,
            metadata: DatabaseExecutionContractFixtures.page.metadata)
        let outcome = DatabaseMutationApplyResult(
            disposition: .completed,
            affectedRecords: DatabaseCountMetadata(value: 12, accuracy: .exact),
            returnedRecords: returnedRecords,
            serverOperationIdentifier: serverOperationIdentifier)
        let status = DatabaseMutationStatusResult(
            serverOperationIdentifier: serverOperationIdentifier,
            state: .completed,
            outcome: outcome)
        #expect(try DatabaseExecutionContractFixtures.roundTrip(status) == status)

        let cancelRequest = DatabaseMutationCancelRequest(
            connectionID: DatabaseConnectionFixtures.connectionID,
            serverOperationIdentifier: serverOperationIdentifier,
            operation: DatabaseExecutionContractFixtures.operation)
        #expect(try DatabaseExecutionContractFixtures.roundTrip(cancelRequest) == cancelRequest)
        let cancellation = DatabaseMutationCancelResult(
            serverOperationIdentifier: serverOperationIdentifier,
            disposition: .alreadyFinished,
            status: status)
        #expect(try DatabaseExecutionContractFixtures.roundTrip(cancellation) == cancellation)

        let outcomeRequest = DatabaseMutationOutcomeGetRequest(
            operationID: DatabaseExecutionContractFixtures.operationID)
        #expect(try DatabaseExecutionContractFixtures.roundTrip(outcomeRequest) == outcomeRequest)
        let persisted = DatabaseMutationOutcomeGetResult(operation: nil, outcome: outcome)
        #expect(try DatabaseExecutionContractFixtures.roundTrip(persisted) == persisted)
    }
}
