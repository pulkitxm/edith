import Foundation
import Testing

@testable import EdithDatabase

private enum DatabaseExecutionValidatorFixtures {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let connectionID = DatabaseConnectionID(
        rawValue: UUID(uuidString: "25D0BF20-3149-4D74-977E-09C6B1353D0E")!)
    static let alternateConnectionID = DatabaseConnectionID(
        rawValue: UUID(uuidString: "60B39B52-D686-4C09-A9EF-D29A4F21FAF7")!)
    static let operationID = DatabaseOperationID(
        rawValue: UUID(uuidString: "B4B6E61B-46DC-46ED-A3CE-BBFA560E3A18")!)

    static var validator: DatabaseExecutionValidator {
        DatabaseExecutionValidator(currentDate: { now })
    }

    static var operation: DatabaseOperationContext {
        DatabaseOperationContext(
            operationID: operationID,
            deadline: now.addingTimeInterval(30))
    }

    static func connection(
        product: DatabaseProduct = .postgresql,
        id: DatabaseConnectionID = connectionID
    ) throws -> DatabaseConnectionDefinition {
        DatabaseConnectionDefinition(
            id: id,
            displayName: product.displayName,
            productHint: product,
            location: .network([
                DatabaseNetworkEndpoint(
                    host: "127.0.0.1",
                    port: try DatabasePort(5_432))
            ]),
            authentication: DatabaseAuthentication(kind: .none),
            tls: DatabaseTLSConfiguration(mode: .disabled, verification: .none),
            limits: DatabaseConnectionLimits(
                connectionTimeout: try DatabaseTimeout(milliseconds: 5_000),
                operationTimeout: try DatabaseTimeout(milliseconds: 30_000),
                poolSize: try DatabasePoolSize(4)),
            environment: DatabaseEnvironmentMetadata(
                kind: .testing,
                label: "testing",
                protection: .standard),
            createdAt: now.addingTimeInterval(-100),
            updatedAt: now.addingTimeInterval(-10))
    }

    static func object(path: [String] = ["public", "orders"]) -> DatabaseObjectIdentifier {
        DatabaseObjectIdentifier(kind: .table, path: path)
    }

    static func target(
        connectionID: DatabaseConnectionID = connectionID,
        object: DatabaseObjectIdentifier? = object()
    ) -> DatabaseTargetIdentifier {
        DatabaseTargetIdentifier(connectionID: connectionID, object: object)
    }

    static func query(
        version: Int = DatabaseQueryRequest.schemaVersion,
        target: DatabaseTargetIdentifier = target(),
        language: DatabaseQueryLanguage = .sql,
        command: String = "SELECT id FROM orders",
        parameters: [DatabaseQueryParameter] = [],
        body: DatabaseValue? = nil,
        operation: DatabaseOperationContext = operation
    ) -> DatabaseQueryRequest {
        DatabaseQueryRequest(
            version: version,
            target: target,
            language: language,
            command: command,
            parameters: parameters,
            body: body,
            operation: operation)
    }

    static func mutation(
        target: DatabaseTargetIdentifier = target()
    ) -> DatabaseDestructiveRequest {
        DatabaseDestructiveRequest(
            target: target,
            predicate: .predicate(
                DatabaseFilterPredicate(
                    field: DatabaseFieldPath("state"),
                    operation: .equal,
                    values: [.string("pending")])),
            payload: .relational(
                product: .postgresql,
                statement: "DELETE FROM orders WHERE state = $1",
                parameters: [
                    DatabaseMutationParameter(name: "state", value: .string("pending"))
                ]))
    }

    static func report(
        product: DatabaseProduct = .postgresql,
        capability: DatabaseCapabilityStatus? = DatabaseCapabilityStatus(
            id: .browse,
            requirement: .sharedRequired,
            availability: .available)
    ) -> DatabaseCapabilityReport {
        DatabaseCapabilityReport(
            productIdentity: DatabaseProductIdentity(
                product: product,
                topology: DatabaseTopology(kind: .standalone)),
            capabilities: capability.map { [$0] } ?? [],
            discoveredAt: now)
    }

    static func field(_ index: Int) -> DatabaseFieldDescriptor {
        DatabaseFieldDescriptor(
            path: DatabaseFieldPath("field\(index)"),
            displayName: "field\(index)",
            typeName: "text",
            isNullable: true,
            isSortable: true,
            isFilterable: true)
    }

    static func record(_ value: DatabaseValue = .signedInteger(1)) -> DatabaseRecord {
        DatabaseRecord(fields: [DatabaseObjectField(name: "value", value: value)])
    }

    static func warning(_ index: Int) -> DatabaseWarning {
        DatabaseWarning(
            code: "warning-\(index)",
            message: "warning",
            severity: .caution)
    }

    static func partialFailure(_ index: Int) -> DatabasePartialFailure {
        DatabasePartialFailure(
            itemIndex: UInt64(index),
            error: DatabaseErrorEnvelope(category: .server, message: "failed"))
    }

    static func page(
        records: [DatabaseRecord] = [record()],
        fields: [DatabaseFieldDescriptor] = [field(0)],
        continuation: DatabaseContinuationToken? = nil,
        warnings: [DatabaseWarning] = [],
        partialFailures: [DatabasePartialFailure] = []
    ) -> DatabasePage<DatabaseRecord> {
        DatabasePage(
            records: records,
            fields: fields,
            nextContinuation: continuation,
            metadata: DatabasePageMetadata(
                completeness: DatabaseResultCompleteness(state: .complete),
                count: DatabaseCountMetadata(
                    value: UInt64(records.count),
                    accuracy: .exact),
                warnings: warnings,
                partialFailures: partialFailures))
    }
}

@Suite struct DatabaseExecutionValidatorTests {
    @Test func acceptsValidContractsAtTheSupportedSchemaVersion() throws {
        let validator = DatabaseExecutionValidatorFixtures.validator
        let connection = try DatabaseExecutionValidatorFixtures.connection()
        let target = DatabaseExecutionValidatorFixtures.target()
        let mutation = DatabaseExecutionValidatorFixtures.mutation()

        try validator.validate(
            DatabaseConnectRequest(
                connectionID: connection.id,
                operation: DatabaseExecutionValidatorFixtures.operation))
        try validator.validate(
            DatabaseDisconnectRequest(
                connectionID: connection.id,
                operation: DatabaseExecutionValidatorFixtures.operation))
        try validator.validate(
            DatabaseConnectionTestRequest(
                connection: connection,
                operation: DatabaseExecutionValidatorFixtures.operation))
        try validator.validate(
            DatabaseCapabilitiesRequest(
                connectionID: connection.id,
                operation: DatabaseExecutionValidatorFixtures.operation))
        try validator.validate(
            DatabaseOperationGetRequest(
                operationID: DatabaseExecutionValidatorFixtures.operationID))
        try validator.validate(DatabaseOperationListRequest())
        try validator.validate(
            DatabaseOperationCancelRequest(
                operationID: DatabaseExecutionValidatorFixtures.operationID))
        try validator.validate(
            DatabaseBrowseRequest(
                target: target,
                operation: DatabaseExecutionValidatorFixtures.operation))
        try validator.validate(DatabaseExecutionValidatorFixtures.query(), connection: connection)
        try validator.validate(
            DatabaseMutationPreviewRequest(
                mutation: mutation,
                operation: DatabaseExecutionValidatorFixtures.operation))
        try validator.validate(
            DatabaseMutationApplyRequest(
                mutation: mutation,
                token: DatabaseConfirmationToken(rawValue: "payload.signature"),
                confirmationText: "PostgreSQL orders",
                operation: DatabaseExecutionValidatorFixtures.operation))
        try validator.validate(
            report: DatabaseExecutionValidatorFixtures.report(),
            connection: connection)
        try validator.require(.browse, in: DatabaseExecutionValidatorFixtures.report())
        try validator.validate(
            page: DatabaseExecutionValidatorFixtures.page(),
            request: DatabasePageRequest())

        let mongoConnection = try DatabaseExecutionValidatorFixtures.connection(product: .mongoDB)
        try validator.validate(
            DatabaseExecutionValidatorFixtures.query(
                language: .mongoQuery,
                command: "find",
                body: .object([])),
            connection: mongoConnection)
    }

    @Test func rejectsEveryUnsupportedRequestVersion() throws {
        let validator = DatabaseExecutionValidatorFixtures.validator
        let connection = try DatabaseExecutionValidatorFixtures.connection()
        let target = DatabaseExecutionValidatorFixtures.target()
        let mutation = DatabaseExecutionValidatorFixtures.mutation()
        let operation = DatabaseExecutionValidatorFixtures.operation

        #expect(
            throws: DatabaseExecutionValidationError.unsupportedVersion(
                contract: "connect request",
                expected: 1,
                actual: 2)
        ) {
            try validator.validate(
                DatabaseConnectRequest(
                    version: 2,
                    connectionID: connection.id,
                    operation: operation))
        }
        #expect(
            throws: DatabaseExecutionValidationError.unsupportedVersion(
                contract: "disconnect request",
                expected: 1,
                actual: 2)
        ) {
            try validator.validate(
                DatabaseDisconnectRequest(
                    version: 2,
                    connectionID: connection.id,
                    operation: operation))
        }

        #expect(
            throws: DatabaseExecutionValidationError.unsupportedVersion(
                contract: "connection test request",
                expected: 1,
                actual: 2)
        ) {
            try validator.validate(
                DatabaseConnectionTestRequest(
                    version: 2,
                    connection: connection,
                    operation: operation))
        }
        #expect(
            throws: DatabaseExecutionValidationError.unsupportedVersion(
                contract: "capabilities request",
                expected: 1,
                actual: 2)
        ) {
            try validator.validate(
                DatabaseCapabilitiesRequest(
                    version: 2,
                    connectionID: connection.id,
                    operation: operation))
        }
        #expect(
            throws: DatabaseExecutionValidationError.unsupportedVersion(
                contract: "browse request",
                expected: 1,
                actual: 2)
        ) {
            try validator.validate(
                DatabaseBrowseRequest(version: 2, target: target, operation: operation))
        }
        #expect(
            throws: DatabaseExecutionValidationError.unsupportedVersion(
                contract: "operation get request",
                expected: 1,
                actual: 2)
        ) {
            try validator.validate(
                DatabaseOperationGetRequest(
                    version: 2,
                    operationID: DatabaseExecutionValidatorFixtures.operationID))
        }
        #expect(
            throws: DatabaseExecutionValidationError.unsupportedVersion(
                contract: "operation list request",
                expected: 1,
                actual: 2)
        ) {
            try validator.validate(DatabaseOperationListRequest(version: 2))
        }
        #expect(
            throws: DatabaseExecutionValidationError.unsupportedVersion(
                contract: "operation cancel request",
                expected: 1,
                actual: 2)
        ) {
            try validator.validate(
                DatabaseOperationCancelRequest(
                    version: 2,
                    operationID: DatabaseExecutionValidatorFixtures.operationID))
        }
        #expect(
            throws: DatabaseExecutionValidationError.unsupportedVersion(
                contract: "query request",
                expected: 1,
                actual: 2)
        ) {
            try validator.validate(DatabaseExecutionValidatorFixtures.query(version: 2))
        }
        #expect(
            throws: DatabaseExecutionValidationError.unsupportedVersion(
                contract: "mutation preview request",
                expected: 1,
                actual: 2)
        ) {
            try validator.validate(
                DatabaseMutationPreviewRequest(
                    version: 2,
                    mutation: mutation,
                    operation: operation))
        }
        #expect(
            throws: DatabaseExecutionValidationError.unsupportedVersion(
                contract: "mutation apply request",
                expected: 1,
                actual: 2)
        ) {
            try validator.validate(
                DatabaseMutationApplyRequest(
                    version: 2,
                    mutation: mutation,
                    token: DatabaseConfirmationToken(rawValue: "token"),
                    confirmationText: "confirm",
                    operation: operation))
        }
    }

    @Test func rejectsDeadlinesAtOrBeforeTheCurrentInstant() throws {
        let validator = DatabaseExecutionValidatorFixtures.validator

        #expect(throws: DatabaseExecutionValidationError.deadlineExceeded) {
            try validator.validate(
                DatabaseOperationContext(deadline: DatabaseExecutionValidatorFixtures.now))
        }
        #expect(throws: DatabaseExecutionValidationError.deadlineExceeded) {
            try validator.validate(
                DatabaseOperationContext(
                    deadline: DatabaseExecutionValidatorFixtures.now.addingTimeInterval(-1)))
        }
        try validator.validate(
            DatabaseOperationContext(
                deadline: DatabaseExecutionValidatorFixtures.now.addingTimeInterval(0.001)))
        try validator.validate(DatabaseOperationContext(deadline: nil))
    }

    @Test func operationHistoryRequestsRequireABoundedPositiveLimit() throws {
        let validator = DatabaseExecutionValidatorFixtures.validator

        for limit in [0, DatabaseExecutionValidator.maximumOperationHistoryCount + 1] {
            #expect(
                throws: DatabaseExecutionValidationError.limitExceeded(
                    name: "operation history results",
                    actual: limit,
                    maximum: DatabaseExecutionValidator.maximumOperationHistoryCount)
            ) {
                try validator.validate(
                    DatabaseOperationListRequest(
                        search: DatabaseOperationHistorySearch(limit: limit)))
            }
        }
    }

    @Test func requiresBoundedNonemptyObjectPathsForBrowse() throws {
        let validator = DatabaseExecutionValidatorFixtures.validator

        #expect(
            throws: DatabaseExecutionValidationError.invalidTarget(
                "The operation requires a database object target.")
        ) {
            try validator.validate(
                DatabaseBrowseRequest(
                    target: DatabaseExecutionValidatorFixtures.target(object: nil)))
        }
        #expect(
            throws: DatabaseExecutionValidationError.invalidTarget(
                "The target object path is empty.")
        ) {
            try validator.validate(
                DatabaseBrowseRequest(
                    target: DatabaseExecutionValidatorFixtures.target(
                        object: DatabaseExecutionValidatorFixtures.object(path: []))))
        }
        #expect(
            throws: DatabaseExecutionValidationError.invalidTarget(
                "The target object path contains an empty segment.")
        ) {
            try validator.validate(
                DatabaseBrowseRequest(
                    target: DatabaseExecutionValidatorFixtures.target(
                        object: DatabaseExecutionValidatorFixtures.object(
                            path: ["public", ""]))))
        }

        let excessSegments = Array(
            repeating: "segment",
            count: DatabaseExecutionValidator.maximumTargetPathSegments + 1)
        #expect(
            throws: DatabaseExecutionValidationError.limitExceeded(
                name: "target path segments",
                actual: excessSegments.count,
                maximum: DatabaseExecutionValidator.maximumTargetPathSegments)
        ) {
            try validator.validate(
                DatabaseBrowseRequest(
                    target: DatabaseExecutionValidatorFixtures.target(
                        object: DatabaseExecutionValidatorFixtures.object(
                            path: excessSegments))))
        }

        let oversizedSegment = String(
            repeating: "x",
            count: DatabaseExecutionValidator.maximumTargetSegmentBytes + 1)
        #expect(
            throws: DatabaseExecutionValidationError.encodedSizeExceeded(
                name: "target path segment",
                actual: oversizedSegment.utf8.count,
                maximum: DatabaseExecutionValidator.maximumTargetSegmentBytes)
        ) {
            try validator.validate(
                DatabaseBrowseRequest(
                    target: DatabaseExecutionValidatorFixtures.target(
                        object: DatabaseExecutionValidatorFixtures.object(
                            path: [oversizedSegment]))))
        }
    }

    @Test func rejectsInvalidQueryShapesAndInputBudgets() throws {
        let validator = DatabaseExecutionValidatorFixtures.validator

        #expect(throws: DatabaseExecutionValidationError.emptyCommand) {
            try validator.validate(DatabaseExecutionValidatorFixtures.query(command: " \n\t "))
        }

        let oversizedCommand = String(
            repeating: "x",
            count: DatabaseExecutionValidator.maximumCommandBytes + 1)
        #expect(
            throws: DatabaseExecutionValidationError.encodedSizeExceeded(
                name: "query command",
                actual: oversizedCommand.utf8.count,
                maximum: DatabaseExecutionValidator.maximumCommandBytes)
        ) {
            try validator.validate(
                DatabaseExecutionValidatorFixtures.query(command: oversizedCommand))
        }

        let excessiveParameters = Array(
            repeating: DatabaseQueryParameter(value: .null),
            count: DatabaseExecutionValidator.maximumParameterCount + 1)
        #expect(
            throws: DatabaseExecutionValidationError.limitExceeded(
                name: "query parameters",
                actual: excessiveParameters.count,
                maximum: DatabaseExecutionValidator.maximumParameterCount)
        ) {
            try validator.validate(
                DatabaseExecutionValidatorFixtures.query(parameters: excessiveParameters))
        }

        let oversizedName = String(
            repeating: "n",
            count: DatabaseExecutionValidator.maximumParameterNameBytes + 1)
        #expect(
            throws: DatabaseExecutionValidationError.encodedSizeExceeded(
                name: "query parameter name",
                actual: oversizedName.utf8.count,
                maximum: DatabaseExecutionValidator.maximumParameterNameBytes)
        ) {
            try validator.validate(
                DatabaseExecutionValidatorFixtures.query(
                    parameters: [DatabaseQueryParameter(name: oversizedName, value: .null)]))
        }

        #expect(throws: DatabaseExecutionValidationError.queryBodyNotAllowed(.sql)) {
            try validator.validate(
                DatabaseExecutionValidatorFixtures.query(body: .object([])))
        }

        let oversizedRequest = DatabaseExecutionValidatorFixtures.query(
            language: .mongoQuery,
            command: "find",
            body: .string(
                String(
                    repeating: "v",
                    count: DatabaseExecutionValidator.maximumRequestBytes)))
        let encodedRequestBytes = try JSONEncoder().encode(oversizedRequest).count
        #expect(encodedRequestBytes > DatabaseExecutionValidator.maximumRequestBytes)
        #expect(
            throws: DatabaseExecutionValidationError.encodedSizeExceeded(
                name: "query request",
                actual: encodedRequestBytes,
                maximum: DatabaseExecutionValidator.maximumRequestBytes)
        ) {
            try validator.validate(oversizedRequest)
        }
    }

    @Test func rejectsUnboundedSortProjectionAndFieldPaths() throws {
        let validator = DatabaseExecutionValidatorFixtures.validator
        let excessiveSorts = Array(
            repeating: DatabaseSort(
                field: DatabaseFieldPath("id"),
                direction: .ascending),
            count: DatabaseExecutionValidator.maximumSortCount + 1)
        #expect(
            throws: DatabaseExecutionValidationError.limitExceeded(
                name: "sort fields",
                actual: excessiveSorts.count,
                maximum: DatabaseExecutionValidator.maximumSortCount)
        ) {
            try validator.validate(
                DatabaseBrowseRequest(
                    target: DatabaseExecutionValidatorFixtures.target(),
                    page: DatabasePageRequest(sorts: excessiveSorts)))
        }

        let excessiveProjection = DatabaseProjection(
            mode: .include,
            fields: (0...DatabaseExecutionValidator.maximumFieldCount).map {
                DatabaseProjectedField(path: DatabaseFieldPath("field\($0)"))
            })
        #expect(
            throws: DatabaseExecutionValidationError.limitExceeded(
                name: "projected fields",
                actual: excessiveProjection.fields.count,
                maximum: DatabaseExecutionValidator.maximumFieldCount)
        ) {
            try validator.validate(
                DatabaseBrowseRequest(
                    target: DatabaseExecutionValidatorFixtures.target(),
                    page: DatabasePageRequest(projection: excessiveProjection)))
        }

        #expect(
            throws: DatabaseExecutionValidationError.invalidTarget("A field path is empty.")
        ) {
            try validator.validate(
                DatabaseBrowseRequest(
                    target: DatabaseExecutionValidatorFixtures.target(),
                    page: DatabasePageRequest(
                        sorts: [
                            DatabaseSort(
                                field: DatabaseFieldPath([]),
                                direction: .ascending)
                        ])))
        }

        let excessivePath = Array(
            repeating: "field",
            count: DatabaseExecutionValidator.maximumFieldPathSegments + 1)
        #expect(
            throws: DatabaseExecutionValidationError.limitExceeded(
                name: "field path segments",
                actual: excessivePath.count,
                maximum: DatabaseExecutionValidator.maximumFieldPathSegments)
        ) {
            try validator.validate(
                DatabaseBrowseRequest(
                    target: DatabaseExecutionValidatorFixtures.target(),
                    page: DatabasePageRequest(
                        projection: DatabaseProjection(
                            mode: .include,
                            fields: [
                                DatabaseProjectedField(path: DatabaseFieldPath(excessivePath))
                            ]))))
        }

        let oversizedAlias = String(
            repeating: "a",
            count: DatabaseExecutionValidator.maximumTargetSegmentBytes + 1)
        #expect(
            throws: DatabaseExecutionValidationError.encodedSizeExceeded(
                name: "projected field alias",
                actual: oversizedAlias.utf8.count,
                maximum: DatabaseExecutionValidator.maximumTargetSegmentBytes)
        ) {
            try validator.validate(
                DatabaseBrowseRequest(
                    target: DatabaseExecutionValidatorFixtures.target(),
                    page: DatabasePageRequest(
                        projection: DatabaseProjection(
                            mode: .include,
                            fields: [
                                DatabaseProjectedField(
                                    path: DatabaseFieldPath("id"),
                                    alias: oversizedAlias)
                            ]))))
        }
    }

    @Test func rejectsEmptyNamedParametersAndObjectFieldNames() throws {
        let validator = DatabaseExecutionValidatorFixtures.validator

        #expect(
            throws: DatabaseExecutionValidationError.invalidTarget(
                "A named query parameter has an empty name.")
        ) {
            try validator.validate(
                DatabaseExecutionValidatorFixtures.query(
                    parameters: [DatabaseQueryParameter(name: "", value: .null)]))
        }
        #expect(
            throws: DatabaseExecutionValidationError.invalidTarget(
                "A database object value contains an empty field name.")
        ) {
            try validator.validate(
                DatabaseExecutionValidatorFixtures.query(
                    parameters: [
                        DatabaseQueryParameter(
                            value: .object([
                                DatabaseObjectField(name: "", value: .null)
                            ]))
                    ]))
        }
    }

    @Test func enforcesRecursiveDepthAndSharedNodeBudgets() throws {
        let validator = DatabaseExecutionValidatorFixtures.validator
        var deepFilter = DatabaseFilter.predicate(
            DatabaseFilterPredicate(
                field: DatabaseFieldPath("id"),
                operation: .isNotNull))
        for _ in 0..<DatabaseExecutionValidator.maximumFilterDepth {
            deepFilter = .not(deepFilter)
        }
        #expect(
            throws: DatabaseExecutionValidationError.limitExceeded(
                name: "input depth",
                actual: DatabaseExecutionValidator.maximumFilterDepth + 1,
                maximum: DatabaseExecutionValidator.maximumFilterDepth)
        ) {
            try validator.validate(
                DatabaseBrowseRequest(
                    target: DatabaseExecutionValidatorFixtures.target(),
                    page: DatabasePageRequest(filter: deepFilter)))
        }

        let parameterValue = DatabaseValue.array(
            Array(
                repeating: .null,
                count: DatabaseExecutionValidator.maximumInputNodes - 2))
        let sharedBudgetRequest = DatabaseExecutionValidatorFixtures.query(
            language: .mongoQuery,
            command: "find",
            parameters: [DatabaseQueryParameter(value: parameterValue)],
            body: .null,
            operation: DatabaseExecutionValidatorFixtures.operation)
        let filter = DatabaseFilter.predicate(
            DatabaseFilterPredicate(
                field: DatabaseFieldPath("id"),
                operation: .isNotNull))
        let request = DatabaseQueryRequest(
            target: sharedBudgetRequest.target,
            language: sharedBudgetRequest.language,
            command: sharedBudgetRequest.command,
            parameters: sharedBudgetRequest.parameters,
            body: sharedBudgetRequest.body,
            page: DatabasePageRequest(filter: filter),
            operation: sharedBudgetRequest.operation)
        #expect(
            throws: DatabaseExecutionValidationError.limitExceeded(
                name: "input nodes",
                actual: DatabaseExecutionValidator.maximumInputNodes + 1,
                maximum: DatabaseExecutionValidator.maximumInputNodes)
        ) {
            try validator.validate(request)
        }
    }

    @Test func bindsQueryTargetsAndLanguagesToTheAuthoritativeConnection() throws {
        let validator = DatabaseExecutionValidatorFixtures.validator
        let validPairs: [(DatabaseProduct, DatabaseQueryLanguage, DatabaseValue?)] = [
            (.postgresql, .sql, nil),
            (.mysql, .sql, nil),
            (.mariaDB, .sql, nil),
            (.sqlite, .sql, nil),
            (.redis, .redisCommand, nil),
            (.valkey, .redisCommand, nil),
            (.mongoDB, .mongoQuery, .object([])),
            (.elasticsearch, .searchQueryDSL, .object([])),
            (.openSearch, .searchQueryDSL, .object([])),
            (.clickHouse, .clickHouseSQL, nil),
        ]

        for (product, language, body) in validPairs {
            let connection = try DatabaseExecutionValidatorFixtures.connection(product: product)
            try validator.validate(
                DatabaseExecutionValidatorFixtures.query(
                    language: language,
                    command: "execute",
                    body: body),
                connection: connection)
        }

        let postgres = try DatabaseExecutionValidatorFixtures.connection()
        #expect(
            throws: DatabaseExecutionValidationError.queryLanguageMismatch(
                language: .redisCommand,
                product: .postgresql)
        ) {
            try validator.validate(
                DatabaseExecutionValidatorFixtures.query(
                    language: .redisCommand,
                    command: "SCAN 0"),
                connection: postgres)
        }

        let clickHouse = try DatabaseExecutionValidatorFixtures.connection(product: .clickHouse)
        #expect(
            throws: DatabaseExecutionValidationError.queryLanguageMismatch(
                language: .sql,
                product: .clickHouse)
        ) {
            try validator.validate(
                DatabaseExecutionValidatorFixtures.query(),
                connection: clickHouse)
        }

        #expect(
            throws: DatabaseExecutionValidationError.invalidTarget(
                "The query target does not belong to the selected connection.")
        ) {
            try validator.validate(
                DatabaseExecutionValidatorFixtures.query(
                    target: DatabaseExecutionValidatorFixtures.target(
                        connectionID: DatabaseExecutionValidatorFixtures.alternateConnectionID)),
                connection: postgres)
        }
    }

    @Test func validatesCapabilityProductsAndPreservesUnavailableReasons() throws {
        let validator = DatabaseExecutionValidatorFixtures.validator
        let connection = try DatabaseExecutionValidatorFixtures.connection()
        let reason = DatabaseCapabilityUnavailableReason(
            category: .permission,
            message: "The current role cannot browse this object.",
            missingPermissions: ["SELECT"])
        let unavailable = DatabaseExecutionValidatorFixtures.report(
            capability: DatabaseCapabilityStatus(
                id: .browse,
                requirement: .sharedRequired,
                availability: .unavailable,
                reason: reason))
        let degraded = DatabaseExecutionValidatorFixtures.report(
            capability: DatabaseCapabilityStatus(
                id: .browse,
                requirement: .sharedRequired,
                availability: .degraded,
                reason: reason))

        try validator.require(.browse, in: degraded)
        #expect(
            throws: DatabaseExecutionValidationError.capabilityUnavailable(.browse, reason)
        ) {
            try validator.require(.browse, in: unavailable)
        }
        #expect(
            throws: DatabaseExecutionValidationError.capabilityUnavailable(.browse, nil)
        ) {
            try validator.require(
                .browse,
                in: DatabaseExecutionValidatorFixtures.report(capability: nil))
        }
        #expect(
            throws: DatabaseExecutionValidationError.productMismatch(
                expected: .postgresql,
                actual: .mysql)
        ) {
            try validator.validate(
                report: DatabaseExecutionValidatorFixtures.report(product: .mysql),
                connection: connection)
        }
    }

    @Test func rejectsEveryUntrustedPageCardinalityOverflow() throws {
        let validator = DatabaseExecutionValidatorFixtures.validator
        let request = DatabasePageRequest(pageSize: try DatabasePageSize(2))

        #expect(
            throws: DatabaseExecutionValidationError.invalidAdapterResult(
                "The adapter returned more records than the requested page size.")
        ) {
            try validator.validate(
                page: DatabaseExecutionValidatorFixtures.page(
                    records: Array(
                        repeating: DatabaseExecutionValidatorFixtures.record(),
                        count: 3)),
                request: request)
        }
        #expect(
            throws: DatabaseExecutionValidationError.invalidAdapterResult(
                "The adapter returned too many field descriptors.")
        ) {
            try validator.validate(
                page: DatabaseExecutionValidatorFixtures.page(
                    records: [],
                    fields: (0...DatabaseExecutionValidator.maximumFieldCount).map(
                        DatabaseExecutionValidatorFixtures.field)),
                request: request)
        }
        #expect(
            throws: DatabaseExecutionValidationError.invalidAdapterResult(
                "The adapter returned too many warnings.")
        ) {
            try validator.validate(
                page: DatabaseExecutionValidatorFixtures.page(
                    warnings: (0...DatabaseExecutionValidator.maximumWarningCount).map(
                        DatabaseExecutionValidatorFixtures.warning)),
                request: request)
        }
        #expect(
            throws: DatabaseExecutionValidationError.invalidAdapterResult(
                "The adapter returned too many partial failures.")
        ) {
            try validator.validate(
                page: DatabaseExecutionValidatorFixtures.page(
                    partialFailures: (0...DatabaseExecutionValidator.maximumPartialFailureCount)
                        .map(
                            DatabaseExecutionValidatorFixtures.partialFailure)),
                request: request)
        }
    }

    @Test func rejectsOversizedContinuationAndEncodedPage() throws {
        let validator = DatabaseExecutionValidatorFixtures.validator
        let request = DatabasePageRequest(pageSize: try DatabasePageSize(1))
        let oversizedContinuation = DatabaseContinuationToken(
            rawValue: String(
                repeating: "c",
                count: DatabaseExecutionValidator.maximumContinuationTokenBytes + 1))

        #expect(
            throws: DatabaseExecutionValidationError.invalidAdapterResult(
                "The adapter returned an oversized continuation token.")
        ) {
            try validator.validate(
                page: DatabaseExecutionValidatorFixtures.page(
                    continuation: oversizedContinuation),
                request: request)
        }

        let oversizedValue = DatabaseValue.string(
            String(
                repeating: "v",
                count: DatabaseExecutionValidator.maximumPageBytes))
        let oversizedPage = DatabaseExecutionValidatorFixtures.page(
            records: [DatabaseExecutionValidatorFixtures.record(oversizedValue)],
            fields: [])
        #expect(
            try JSONEncoder().encode(oversizedPage).count
                > DatabaseExecutionValidator.maximumPageBytes)
        #expect(
            throws: DatabaseExecutionValidationError.invalidAdapterResult(
                "The adapter returned an oversized page.")
        ) {
            try validator.validate(page: oversizedPage, request: request)
        }
    }

    @Test func acceptsTheMaximumPublicRecordPageWithoutTruncation() throws {
        let validator = DatabaseExecutionValidatorFixtures.validator
        let request = DatabasePageRequest(pageSize: .maximumSize)
        let records = Array(
            repeating: DatabaseExecutionValidatorFixtures.record(),
            count: DatabasePageSize.maximumSize.value)

        try validator.validate(
            page: DatabaseExecutionValidatorFixtures.page(records: records, fields: []),
            request: request)
    }

    @Test func mutationContractsRejectInvalidTargetsAndOversizedAuthorizationInput() throws {
        let validator = DatabaseExecutionValidatorFixtures.validator
        let invalidMutation = DatabaseExecutionValidatorFixtures.mutation(
            target: DatabaseExecutionValidatorFixtures.target(
                object: DatabaseExecutionValidatorFixtures.object(path: [])))

        #expect(
            throws: DatabaseExecutionValidationError.invalidTarget(
                "The target object path is empty.")
        ) {
            try validator.validate(DatabaseMutationPreviewRequest(mutation: invalidMutation))
        }

        let mutation = DatabaseExecutionValidatorFixtures.mutation()
        let oversizedApply = DatabaseMutationApplyRequest(
            mutation: mutation,
            token: DatabaseConfirmationToken(rawValue: "token"),
            confirmationText: String(
                repeating: "x",
                count: DatabaseExecutionValidator.maximumRequestBytes),
            operation: DatabaseExecutionValidatorFixtures.operation)
        let encodedBytes = try JSONEncoder().encode(oversizedApply).count
        #expect(encodedBytes > DatabaseExecutionValidator.maximumRequestBytes)
        #expect(
            throws: DatabaseExecutionValidationError.encodedSizeExceeded(
                name: "mutation apply request",
                actual: encodedBytes,
                maximum: DatabaseExecutionValidator.maximumRequestBytes)
        ) {
            try validator.validate(oversizedApply)
        }
    }
}
