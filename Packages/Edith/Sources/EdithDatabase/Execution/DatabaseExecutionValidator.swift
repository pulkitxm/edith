import Foundation

enum DatabaseExecutionValidationError: Error, Equatable, Sendable {
    case unsupportedVersion(contract: String, expected: Int, actual: Int)
    case deadlineExceeded
    case operationIdentifierAlreadyExists(DatabaseOperationID)
    case identifierAlreadyExists(String)
    case connectionDefinitionChanged(DatabaseConnectionID)
    case savedQueryDefinitionChanged(DatabaseSavedQueryID)
    case runtimeOwnerNotActive
    case invalidIdentifier(String)
    case invalidDefinition(String)
    case duplicateValue(String)
    case suspiciousOptionName
    case invalidTimestamp(String)
    case invalidTarget(String)
    case emptyCommand
    case queryLanguageMismatch(language: DatabaseQueryLanguage, product: DatabaseProduct)
    case queryBodyNotAllowed(DatabaseQueryLanguage)
    case limitExceeded(name: String, actual: Int, maximum: Int)
    case encodedSizeExceeded(name: String, actual: Int, maximum: Int)
    case productMismatch(expected: DatabaseProduct, actual: DatabaseProduct)
    case capabilityUnavailable(DatabaseCapabilityID, DatabaseCapabilityUnavailableReason?)
    case invalidAdapterResult(String)
}

struct DatabaseExecutionValidator: Sendable {
    static let maximumCommandBytes = 1_048_576
    static let maximumRequestBytes = 2_097_152
    static let maximumParameterCount = 512
    static let maximumParameterNameBytes = 1_024
    static let maximumTargetPathSegments = 64
    static let maximumTargetSegmentBytes = 4_096
    static let maximumSortCount = 64
    static let maximumFieldPathSegments = 64
    static let maximumFilterDepth = 32
    static let maximumInputNodes = 10_000
    static let maximumFieldCount = 512
    static let maximumWarningCount = 100
    static let maximumPartialFailureCount = 100
    static let maximumPageBytes = 16_777_216
    static let maximumContinuationTokenBytes = 131_072
    static let maximumOperationHistoryCount = 1_000
    static let maximumManagementListCount = 500
    static let maximumManagementOffset = 1_000_000
    static let maximumNameBytes = 512
    static let maximumGroupBytes = 512
    static let maximumTagCount = 64
    static let maximumTagBytes = 128
    static let maximumEndpointCount = 64
    static let maximumOptionCount = 128
    static let maximumOptionNameBytes = 256
    static let maximumOptionStringBytes = 16_384
    static let maximumReferenceCount = 64

    private let currentDate: @Sendable () -> Date

    init(currentDate: @escaping @Sendable () -> Date = { Date() }) {
        self.currentDate = currentDate
    }

    func validate(_ request: DatabaseConnectRequest) throws {
        try Self.validateVersion(
            request.version,
            expected: DatabaseConnectRequest.schemaVersion,
            contract: "connect request")
        try validate(request.operation)
        try Self.validateEncodedSize(request, name: "connect request")
    }

    func validate(_ request: DatabaseDisconnectRequest) throws {
        try Self.validateVersion(
            request.version,
            expected: DatabaseDisconnectRequest.schemaVersion,
            contract: "disconnect request")
        try validate(request.operation)
        try Self.validateEncodedSize(request, name: "disconnect request")
    }

    func validate(_ request: DatabaseConnectionTestRequest) throws {
        try Self.validateVersion(
            request.version,
            expected: DatabaseConnectionTestRequest.schemaVersion,
            contract: "connection test request")
        try validate(request.operation)
        try validate(request.connection)
        try Self.validateEncodedSize(request, name: "connection test request")
    }

    func validate(_ request: DatabaseConnectionListRequest) throws {
        try Self.validateVersion(
            request.version,
            expected: DatabaseConnectionListRequest.schemaVersion,
            contract: "connection list request")
        try Self.validate(request.search)
        try Self.validateEncodedSize(request, name: "connection list request")
    }

    func validate(_ request: DatabaseConnectionGetRequest) throws {
        try Self.validateVersion(
            request.version,
            expected: DatabaseConnectionGetRequest.schemaVersion,
            contract: "connection get request")
        try Self.validate(request.connectionID, name: "connection identifier")
        try Self.validateEncodedSize(request, name: "connection get request")
    }

    func validate(_ request: DatabaseConnectionSaveRequest) throws {
        try Self.validateVersion(
            request.version,
            expected: DatabaseConnectionSaveRequest.schemaVersion,
            contract: "connection save request")
        try validate(request.connection)
        try Self.validateEncodedSize(request, name: "connection save request")
    }

    func validate(_ request: DatabaseConnectionEditRequest) throws {
        try Self.validateVersion(
            request.version,
            expected: DatabaseConnectionEditRequest.schemaVersion,
            contract: "connection edit request")
        try Self.validate(request.connectionID, name: "connection identifier")
        guard request.connectionID == request.connection.id else {
            throw DatabaseExecutionValidationError.invalidIdentifier("connection identifier")
        }
        try validate(request.connection)
        try Self.validateEncodedSize(request, name: "connection edit request")
    }

    func validate(_ request: DatabaseConnectionDuplicateRequest) throws {
        try Self.validateVersion(
            request.version,
            expected: DatabaseConnectionDuplicateRequest.schemaVersion,
            contract: "connection duplicate request")
        try Self.validate(request.connectionID, name: "connection identifier")
        try Self.validateRequiredText(
            request.displayName,
            name: "connection name",
            maximum: Self.maximumNameBytes)
        try Self.validateEncodedSize(request, name: "connection duplicate request")
    }

    func validate(_ request: DatabaseConnectionRenameRequest) throws {
        try Self.validateVersion(
            request.version,
            expected: DatabaseConnectionRenameRequest.schemaVersion,
            contract: "connection rename request")
        try Self.validate(request.connectionID, name: "connection identifier")
        try Self.validateRequiredText(
            request.displayName,
            name: "connection name",
            maximum: Self.maximumNameBytes)
        try Self.validateEncodedSize(request, name: "connection rename request")
    }

    func validate(_ request: DatabaseConnectionDeleteRequest) throws {
        try Self.validateVersion(
            request.version,
            expected: DatabaseConnectionDeleteRequest.schemaVersion,
            contract: "connection delete request")
        try Self.validate(request.connectionID, name: "connection identifier")
        try Self.validateEncodedSize(request, name: "connection delete request")
    }

    func validate(_ request: DatabaseSavedQueryListRequest) throws {
        try Self.validateVersion(
            request.version,
            expected: DatabaseSavedQueryListRequest.schemaVersion,
            contract: "saved query list request")
        try Self.validate(request.search)
        try Self.validateEncodedSize(request, name: "saved query list request")
    }

    func validate(_ request: DatabaseSavedQueryGetRequest) throws {
        try Self.validateVersion(
            request.version,
            expected: DatabaseSavedQueryGetRequest.schemaVersion,
            contract: "saved query get request")
        try Self.validate(request.queryID, name: "saved query identifier")
        try Self.validateEncodedSize(request, name: "saved query get request")
    }

    func validate(_ request: DatabaseSavedQuerySaveRequest) throws {
        try Self.validateVersion(
            request.version,
            expected: DatabaseSavedQuerySaveRequest.schemaVersion,
            contract: "saved query save request")
        try validate(request.query)
        try Self.validateEncodedSize(request, name: "saved query save request")
    }

    func validate(_ request: DatabaseSavedQueryDuplicateRequest) throws {
        try Self.validateVersion(
            request.version,
            expected: DatabaseSavedQueryDuplicateRequest.schemaVersion,
            contract: "saved query duplicate request")
        try Self.validate(request.queryID, name: "saved query identifier")
        try Self.validateRequiredText(
            request.name,
            name: "saved query name",
            maximum: Self.maximumNameBytes)
        try Self.validateEncodedSize(request, name: "saved query duplicate request")
    }

    func validate(_ request: DatabaseSavedQueryRenameRequest) throws {
        try Self.validateVersion(
            request.version,
            expected: DatabaseSavedQueryRenameRequest.schemaVersion,
            contract: "saved query rename request")
        try Self.validate(request.queryID, name: "saved query identifier")
        try Self.validateRequiredText(
            request.name,
            name: "saved query name",
            maximum: Self.maximumNameBytes)
        try Self.validateEncodedSize(request, name: "saved query rename request")
    }

    func validate(_ request: DatabaseSavedQueryDeleteRequest) throws {
        try Self.validateVersion(
            request.version,
            expected: DatabaseSavedQueryDeleteRequest.schemaVersion,
            contract: "saved query delete request")
        try Self.validate(request.queryID, name: "saved query identifier")
        try Self.validateEncodedSize(request, name: "saved query delete request")
    }

    func validate(_ request: DatabaseCapabilitiesRequest) throws {
        try Self.validateVersion(
            request.version,
            expected: DatabaseCapabilitiesRequest.schemaVersion,
            contract: "capabilities request")
        try validate(request.operation)
        try Self.validateEncodedSize(request, name: "capabilities request")
    }

    func validate(_ request: DatabaseOperationGetRequest) throws {
        try Self.validateVersion(
            request.version,
            expected: DatabaseOperationGetRequest.schemaVersion,
            contract: "operation get request")
        try Self.validateEncodedSize(request, name: "operation get request")
    }

    func validate(_ request: DatabaseOperationListRequest) throws {
        try Self.validateVersion(
            request.version,
            expected: DatabaseOperationListRequest.schemaVersion,
            contract: "operation list request")
        guard (1...Self.maximumOperationHistoryCount).contains(request.search.limit) else {
            throw DatabaseExecutionValidationError.limitExceeded(
                name: "operation history results",
                actual: request.search.limit,
                maximum: Self.maximumOperationHistoryCount)
        }
        try Self.validateEncodedSize(request, name: "operation list request")
    }

    func validate(_ request: DatabaseOperationCancelRequest) throws {
        try Self.validateVersion(
            request.version,
            expected: DatabaseOperationCancelRequest.schemaVersion,
            contract: "operation cancel request")
        try Self.validateEncodedSize(request, name: "operation cancel request")
    }

    func validate(_ request: DatabaseBrowseRequest) throws {
        try Self.validateVersion(
            request.version,
            expected: DatabaseBrowseRequest.schemaVersion,
            contract: "browse request")
        try validate(request.operation)
        try Self.validateTarget(request.target, requiresObject: true)
        try Self.validatePageRequest(request.page)
        try Self.validateEncodedSize(request, name: "browse request")
    }

    func validate(_ request: DatabaseQueryRequest) throws {
        try Self.validateVersion(
            request.version,
            expected: DatabaseQueryRequest.schemaVersion,
            contract: "query request")
        try validate(request.operation)
        try Self.validateTarget(request.target, requiresObject: false)
        guard !request.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DatabaseExecutionValidationError.emptyCommand
        }
        try Self.validateByteLimit(
            request.command,
            name: "query command",
            maximum: Self.maximumCommandBytes)
        guard request.parameters.count <= Self.maximumParameterCount else {
            throw DatabaseExecutionValidationError.limitExceeded(
                name: "query parameters",
                actual: request.parameters.count,
                maximum: Self.maximumParameterCount)
        }
        for parameter in request.parameters {
            if let name = parameter.name {
                guard !name.isEmpty else {
                    throw DatabaseExecutionValidationError.invalidTarget(
                        "A named query parameter has an empty name.")
                }
                try Self.validateByteLimit(
                    name,
                    name: "query parameter name",
                    maximum: Self.maximumParameterNameBytes)
            }
        }
        var inputNodes = 0
        for parameter in request.parameters {
            try Self.validateValue(parameter.value, nodes: &inputNodes)
        }
        if let body = request.body {
            try Self.validateValue(body, nodes: &inputNodes)
        }
        try Self.validatePageRequest(request.page, nodes: &inputNodes)
        switch request.language {
        case .sql, .redisCommand, .clickHouseSQL:
            if request.body != nil {
                throw DatabaseExecutionValidationError.queryBodyNotAllowed(request.language)
            }
        case .mongoQuery, .searchQueryDSL:
            break
        }
        try Self.validateEncodedSize(request, name: "query request")
    }

    func validate(
        _ request: DatabaseQueryRequest,
        connection: DatabaseConnectionDefinition
    ) throws {
        try validate(request)
        guard request.target.connectionID == connection.id else {
            throw DatabaseExecutionValidationError.invalidTarget(
                "The query target does not belong to the selected connection.")
        }
        let matches =
            switch request.language {
            case .sql:
                connection.productHint.family == .relational
            case .redisCommand:
                connection.productHint.family == .keyValue
            case .mongoQuery:
                connection.productHint.family == .document
            case .searchQueryDSL:
                connection.productHint.family == .search
            case .clickHouseSQL:
                connection.productHint == .clickHouse
            }
        guard matches else {
            throw DatabaseExecutionValidationError.queryLanguageMismatch(
                language: request.language,
                product: connection.productHint)
        }
    }

    func validate(_ request: DatabaseMutationPreviewRequest) throws {
        try Self.validateVersion(
            request.version,
            expected: DatabaseMutationPreviewRequest.schemaVersion,
            contract: "mutation preview request")
        try validate(request.operation)
        try Self.validateTarget(request.mutation.target, requiresObject: false)
        try Self.validateEncodedSize(request, name: "mutation preview request")
    }

    func validate(_ request: DatabaseMutationApplyRequest) throws {
        try Self.validateVersion(
            request.version,
            expected: DatabaseMutationApplyRequest.schemaVersion,
            contract: "mutation apply request")
        try validate(request.operation)
        try Self.validateTarget(request.mutation.target, requiresObject: false)
        try Self.validateEncodedSize(request, name: "mutation apply request")
    }

    func validate(_ request: DatabaseMutationStatusRequest) throws {
        try Self.validateVersion(
            request.version,
            expected: DatabaseMutationStatusRequest.schemaVersion,
            contract: "mutation status request")
        try validate(request.operation)
        try Self.validate(request.connectionID, name: "connection identifier")
        try Self.validateRequiredText(
            request.serverOperationIdentifier,
            name: "server operation identifier",
            maximum: DatabaseAdapterBounds.maximumServerOperationIdentifierBytes)
        try Self.validateEncodedSize(request, name: "mutation status request")
    }

    func validate(_ request: DatabaseMutationCancelRequest) throws {
        try Self.validateVersion(
            request.version,
            expected: DatabaseMutationCancelRequest.schemaVersion,
            contract: "mutation cancel request")
        try validate(request.operation)
        try Self.validate(request.connectionID, name: "connection identifier")
        try Self.validateRequiredText(
            request.serverOperationIdentifier,
            name: "server operation identifier",
            maximum: DatabaseAdapterBounds.maximumServerOperationIdentifierBytes)
        try Self.validateEncodedSize(request, name: "mutation cancel request")
    }

    func validate(_ request: DatabaseMutationOutcomeGetRequest) throws {
        try Self.validateVersion(
            request.version,
            expected: DatabaseMutationOutcomeGetRequest.schemaVersion,
            contract: "mutation outcome get request")
        try Self.validateEncodedSize(request, name: "mutation outcome get request")
    }

    func validate(_ operation: DatabaseOperationContext) throws {
        if let deadline = operation.deadline, deadline <= currentDate() {
            throw DatabaseExecutionValidationError.deadlineExceeded
        }
    }

    func validate(
        report: DatabaseCapabilityReport,
        connection: DatabaseConnectionDefinition
    ) throws {
        guard report.productIdentity.product == connection.productHint else {
            throw DatabaseExecutionValidationError.productMismatch(
                expected: connection.productHint,
                actual: report.productIdentity.product)
        }
    }

    func require(
        _ capability: DatabaseCapabilityID,
        in report: DatabaseCapabilityReport
    ) throws {
        guard report.supports(capability) else {
            throw DatabaseExecutionValidationError.capabilityUnavailable(
                capability,
                report.unavailableReason(for: capability))
        }
    }

    func validate(
        page: DatabasePage<DatabaseRecord>,
        request: DatabasePageRequest
    ) throws {
        guard page.records.count <= request.pageSize.value else {
            throw DatabaseExecutionValidationError.invalidAdapterResult(
                "The adapter returned more records than the requested page size.")
        }
        guard page.fields.count <= Self.maximumFieldCount else {
            throw DatabaseExecutionValidationError.invalidAdapterResult(
                "The adapter returned too many field descriptors.")
        }
        guard page.metadata.warnings.count <= Self.maximumWarningCount else {
            throw DatabaseExecutionValidationError.invalidAdapterResult(
                "The adapter returned too many warnings.")
        }
        guard page.metadata.partialFailures.count <= Self.maximumPartialFailureCount else {
            throw DatabaseExecutionValidationError.invalidAdapterResult(
                "The adapter returned too many partial failures.")
        }
        if let continuation = page.nextContinuation {
            guard continuation.rawValue.utf8.count <= Self.maximumContinuationTokenBytes else {
                throw DatabaseExecutionValidationError.invalidAdapterResult(
                    "The adapter returned an oversized continuation token.")
            }
        }
        let encoded = try JSONEncoder().encode(page)
        guard encoded.count <= Self.maximumPageBytes else {
            throw DatabaseExecutionValidationError.invalidAdapterResult(
                "The adapter returned an oversized page.")
        }
    }

    func validate(_ connection: DatabaseConnectionDefinition) throws {
        try Self.validateVersion(
            connection.version,
            expected: DatabaseConnectionDefinition.schemaVersion,
            contract: "connection definition")
        try Self.validate(connection.id, name: "connection identifier")
        try Self.validateRequiredText(
            connection.displayName,
            name: "connection name",
            maximum: Self.maximumNameBytes)
        try Self.validateRequiredText(
            connection.environment.label,
            name: "environment label",
            maximum: Self.maximumNameBytes)
        try Self.validateOptionalText(
            connection.username,
            name: "username",
            maximum: Self.maximumNameBytes)
        try Self.validateOptionalText(
            connection.group,
            name: "connection group",
            maximum: Self.maximumGroupBytes)
        try Self.validateOptionalText(
            connection.color,
            name: "connection color",
            maximum: Self.maximumNameBytes)
        try Self.validateOptionalText(
            connection.namespaces.catalog,
            name: "default catalog",
            maximum: Self.maximumNameBytes)
        try Self.validateOptionalText(
            connection.namespaces.schema,
            name: "default schema",
            maximum: Self.maximumNameBytes)
        try Self.validateOptionalText(
            connection.namespaces.database,
            name: "default database",
            maximum: Self.maximumNameBytes)
        try Self.validateOptionalText(
            connection.namespaces.logicalDatabase,
            name: "default logical database",
            maximum: Self.maximumNameBytes)
        try Self.validate(connection.location, product: connection.productHint)
        try Self.validate(connection.authentication, tls: connection.tls)
        try Self.validate(connection.tls)
        if let tunnel = connection.tunnel {
            try Self.validate(tunnel)
        }
        try Self.validateTags(connection.tags)
        try Self.validateOptions(connection.options)
        try Self.validateTimestamps(
            createdAt: connection.createdAt,
            updatedAt: connection.updatedAt,
            additional: [connection.lastTestedAt, connection.lastUsedAt])
    }

    func validate(_ query: DatabaseSavedQuery) throws {
        try Self.validate(query.id, name: "saved query identifier")
        if let connectionID = query.connectionID {
            try Self.validate(connectionID, name: "saved query connection identifier")
        }
        try Self.validateRequiredText(
            query.name,
            name: "saved query name",
            maximum: Self.maximumNameBytes)
        try Self.validateRequiredText(
            query.text,
            name: "saved query text",
            maximum: Self.maximumCommandBytes)
        try Self.validateTags(query.tags)
        try Self.validateTimestamps(
            createdAt: query.createdAt,
            updatedAt: query.updatedAt,
            additional: [])
    }

    func validate(
        _ query: DatabaseSavedQuery,
        connection: DatabaseConnectionDefinition?
    ) throws {
        try validate(query)
        guard let connection else { return }
        guard query.connectionID == connection.id else {
            throw DatabaseExecutionValidationError.invalidIdentifier(
                "saved query connection identifier")
        }
        let matches =
            switch query.language {
            case .sql:
                connection.productHint.family == .relational
            case .redisCommand:
                connection.productHint.family == .keyValue
            case .mongoQuery:
                connection.productHint.family == .document
            case .searchQueryDSL:
                connection.productHint.family == .search
            case .clickHouseSQL:
                connection.productHint == .clickHouse
            }
        guard matches else {
            throw DatabaseExecutionValidationError.queryLanguageMismatch(
                language: query.language,
                product: connection.productHint)
        }
    }

    func validate(
        connections: [DatabaseConnectionDefinition],
        limit: Int
    ) throws {
        guard connections.count <= limit else {
            throw DatabaseExecutionValidationError.invalidAdapterResult(
                "The metadata store returned too many connections.")
        }
        for connection in connections {
            try validateStored(connection)
        }
        do {
            try Self.validateResponseSize(connections, name: "connection list result")
        } catch {
            throw DatabaseExecutionValidationError.invalidAdapterResult(
                "The metadata store returned an oversized connection list.")
        }
    }

    func validate(
        queries: [DatabaseSavedQuery],
        limit: Int
    ) throws {
        guard queries.count <= limit else {
            throw DatabaseExecutionValidationError.invalidAdapterResult(
                "The metadata store returned too many saved queries.")
        }
        do {
            try Self.validateResponseSize(queries, name: "saved query list result")
        } catch {
            throw DatabaseExecutionValidationError.invalidAdapterResult(
                "The metadata store returned an oversized saved query list.")
        }
    }

    func validateStored(_ connection: DatabaseConnectionDefinition) throws {
        do {
            try validate(connection)
        } catch {
            throw DatabaseExecutionValidationError.invalidAdapterResult(
                "The metadata store returned an invalid connection definition.")
        }
    }

    func validateStored(
        _ query: DatabaseSavedQuery,
        connection: DatabaseConnectionDefinition?
    ) throws {
        do {
            try validate(query, connection: connection)
        } catch {
            throw DatabaseExecutionValidationError.invalidAdapterResult(
                "The metadata store returned an invalid saved query.")
        }
    }

    private static func validate(_ search: DatabaseConnectionSearch) throws {
        try validateListBounds(limit: search.limit, offset: search.offset)
        try validateOptionalText(
            search.text,
            name: "connection search text",
            maximum: maximumNameBytes)
        try validateOptionalText(
            search.group,
            name: "connection search group",
            maximum: maximumGroupBytes)
        try validateTags(Array(search.tags))
    }

    private static func validate(_ search: DatabaseSavedQuerySearch) throws {
        try validateListBounds(limit: search.limit, offset: search.offset)
        try validateOptionalText(
            search.text,
            name: "saved query search text",
            maximum: maximumNameBytes)
        if let connectionID = search.connectionID {
            try validate(connectionID, name: "saved query connection identifier")
        }
        try validateTags(Array(search.tags))
    }

    private static func validateListBounds(limit: Int, offset: Int) throws {
        guard limit > 0, offset >= 0 else {
            throw DatabaseExecutionValidationError.invalidDefinition(
                "Management list bounds cannot be negative or zero.")
        }
        guard limit <= maximumManagementListCount else {
            throw DatabaseExecutionValidationError.limitExceeded(
                name: "management list results",
                actual: limit,
                maximum: maximumManagementListCount)
        }
        guard offset <= maximumManagementOffset else {
            throw DatabaseExecutionValidationError.limitExceeded(
                name: "management list offset",
                actual: offset,
                maximum: maximumManagementOffset)
        }
    }

    private static func validate(
        _ location: DatabaseConnectionLocation,
        product: DatabaseProduct
    ) throws {
        switch location {
        case let .network(endpoints):
            guard product != .sqlite else {
                throw DatabaseExecutionValidationError.invalidDefinition(
                    "SQLite cannot use a network location.")
            }
            guard !endpoints.isEmpty else {
                throw DatabaseExecutionValidationError.invalidDefinition(
                    "A network connection requires an endpoint.")
            }
            guard endpoints.count <= maximumEndpointCount else {
                throw DatabaseExecutionValidationError.limitExceeded(
                    name: "connection endpoints",
                    actual: endpoints.count,
                    maximum: maximumEndpointCount)
            }
            var endpointKeys: Set<String> = []
            for endpoint in endpoints {
                try validateRequiredText(
                    endpoint.host,
                    name: "endpoint host",
                    maximum: maximumNameBytes)
                let key =
                    "\(endpoint.host.lowercased()):\(endpoint.port.value):\(endpoint.role.rawValue)"
                guard endpointKeys.insert(key).inserted else {
                    throw DatabaseExecutionValidationError.duplicateValue(
                        "connection endpoint")
                }
            }
        case let .sqlite(location):
            guard product == .sqlite else {
                throw DatabaseExecutionValidationError.invalidDefinition(
                    "Only SQLite can use a SQLite location.")
            }
            try validateRequiredText(
                location.path,
                name: "SQLite path",
                maximum: maximumTargetSegmentBytes)
            if let reference = location.fileReference {
                try validate(reference.identifier, name: "SQLite file reference")
                guard reference.kind == .sqliteBookmark else {
                    throw DatabaseExecutionValidationError.invalidDefinition(
                        "The SQLite file reference has the wrong kind.")
                }
            }
        case let .memory(name):
            guard product == .sqlite else {
                throw DatabaseExecutionValidationError.invalidDefinition(
                    "Only SQLite can use an in-memory location.")
            }
            try validateOptionalText(
                name,
                name: "in-memory database name",
                maximum: maximumNameBytes)
        }
    }

    private static func validate(
        _ authentication: DatabaseAuthentication,
        tls: DatabaseTLSConfiguration
    ) throws {
        try validateOptionalText(
            authentication.source,
            name: "authentication source",
            maximum: maximumNameBytes)
        guard authentication.secretReferences.count <= maximumReferenceCount else {
            throw DatabaseExecutionValidationError.limitExceeded(
                name: "credential references",
                actual: authentication.secretReferences.count,
                maximum: maximumReferenceCount)
        }
        var identifiers: Set<UUID> = []
        let references = authentication.secretReferences + [tls.clientPrivateKey].compactMap { $0 }
        for reference in references {
            try validate(reference.identifier, name: "credential reference")
            guard reference.purpose != .confirmationSigningKey,
                reference.purpose != .continuationSigningKey
            else {
                throw DatabaseExecutionValidationError.invalidDefinition(
                    "A connection cannot reference a signing key.")
            }
            guard identifiers.insert(reference.identifier).inserted else {
                throw DatabaseExecutionValidationError.duplicateValue(
                    "credential reference")
            }
        }
        let purposes = authentication.secretReferences.map(\.purpose)
        switch authentication.kind {
        case .none:
            guard purposes.isEmpty, authentication.source == nil else {
                throw DatabaseExecutionValidationError.invalidDefinition(
                    "Authentication without credentials cannot contain credential metadata.")
            }
        case .password, .usernameAndPassword, .scram:
            guard purposes == [.password] else {
                throw DatabaseExecutionValidationError.invalidDefinition(
                    "Password authentication requires one password reference.")
            }
        case .token:
            guard purposes == [.token] else {
                throw DatabaseExecutionValidationError.invalidDefinition(
                    "Token authentication requires one token reference.")
            }
        case .apiKey:
            guard Set(purposes) == [.apiKeyIdentifier, .apiKeySecret], purposes.count == 2 else {
                throw DatabaseExecutionValidationError.invalidDefinition(
                    "API key authentication requires identifier and secret references.")
            }
        case .x509:
            guard purposes.isEmpty,
                tls.clientCertificate != nil,
                tls.clientPrivateKey != nil
            else {
                throw DatabaseExecutionValidationError.invalidDefinition(
                    "X.509 authentication requires a client certificate and private key.")
            }
        case .cloudIdentity:
            guard authentication.source != nil,
                purposes.allSatisfy({ $0 == .token })
            else {
                throw DatabaseExecutionValidationError.invalidDefinition(
                    "Cloud identity authentication requires a source and optional token reference.")
            }
        }
    }

    private static func validate(_ tls: DatabaseTLSConfiguration) throws {
        try validateOptionalText(
            tls.serverName,
            name: "TLS server name",
            maximum: maximumNameBytes)
        if let certificateAuthority = tls.certificateAuthority {
            try validate(certificateAuthority.identifier, name: "certificate authority reference")
            guard certificateAuthority.kind == .certificateAuthority else {
                throw DatabaseExecutionValidationError.invalidDefinition(
                    "The certificate authority reference has the wrong kind.")
            }
        }
        if let clientCertificate = tls.clientCertificate {
            try validate(clientCertificate.identifier, name: "client certificate reference")
            guard clientCertificate.kind == .clientCertificate else {
                throw DatabaseExecutionValidationError.invalidDefinition(
                    "The client certificate reference has the wrong kind.")
            }
        }
        if let clientPrivateKey = tls.clientPrivateKey {
            guard clientPrivateKey.purpose == .clientPrivateKey else {
                throw DatabaseExecutionValidationError.invalidDefinition(
                    "The TLS private key reference has the wrong purpose.")
            }
        }
        guard (tls.clientCertificate == nil) == (tls.clientPrivateKey == nil) else {
            throw DatabaseExecutionValidationError.invalidDefinition(
                "A client certificate and private key must be configured together.")
        }
        let resourceIdentifiers = [tls.certificateAuthority, tls.clientCertificate]
            .compactMap { $0?.identifier }
        guard Set(resourceIdentifiers).count == resourceIdentifiers.count else {
            throw DatabaseExecutionValidationError.duplicateValue("TLS resource reference")
        }
        if tls.mode == .disabled {
            guard tls.verification == .none,
                tls.serverName == nil,
                tls.certificateAuthority == nil,
                tls.clientCertificate == nil,
                tls.clientPrivateKey == nil
            else {
                throw DatabaseExecutionValidationError.invalidDefinition(
                    "Disabled TLS cannot contain TLS verification or identity metadata.")
            }
        }
    }

    private static func validate(_ tunnel: DatabaseTunnelDefinition) throws {
        try validateRequiredText(
            tunnel.machineIdentifier,
            name: "tunnel machine identifier",
            maximum: maximumNameBytes)
        try validateRequiredText(
            tunnel.remoteEndpoint.host,
            name: "tunnel endpoint host",
            maximum: maximumNameBytes)
        try validateRequiredText(
            tunnel.localBindAddress,
            name: "tunnel bind address",
            maximum: maximumNameBytes)
    }

    private static func validateTags(_ tags: [String]) throws {
        guard tags.count <= maximumTagCount else {
            throw DatabaseExecutionValidationError.limitExceeded(
                name: "tags",
                actual: tags.count,
                maximum: maximumTagCount)
        }
        var normalized: Set<String> = []
        for tag in tags {
            try validateRequiredText(tag, name: "tag", maximum: maximumTagBytes)
            let value = tag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard normalized.insert(value).inserted else {
                throw DatabaseExecutionValidationError.duplicateValue("tag")
            }
        }
    }

    private static func validateOptions(_ options: [DatabaseNonSecretOption]) throws {
        guard options.count <= maximumOptionCount else {
            throw DatabaseExecutionValidationError.limitExceeded(
                name: "connection options",
                actual: options.count,
                maximum: maximumOptionCount)
        }
        var normalized: Set<String> = []
        for option in options {
            try validateRequiredText(
                option.name,
                name: "connection option name",
                maximum: maximumOptionNameBytes)
            let canonical = option.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard normalized.insert(canonical).inserted else {
                throw DatabaseExecutionValidationError.duplicateValue("connection option")
            }
            let compact = String(canonical.filter { $0.isLetter || $0.isNumber })
            let secretMarkers = [
                "password", "passwd", "secret", "token", "apikey", "privatekey",
                "credential",
            ]
            guard !secretMarkers.contains(where: compact.contains) else {
                throw DatabaseExecutionValidationError.suspiciousOptionName
            }
            if case let .string(value) = option.value {
                try validateByteLimit(
                    value,
                    name: "connection option value",
                    maximum: maximumOptionStringBytes)
            }
        }
    }

    private static func validateTimestamps(
        createdAt: Date,
        updatedAt: Date,
        additional: [Date?]
    ) throws {
        let dates = [createdAt, updatedAt] + additional.compactMap { $0 }
        guard dates.allSatisfy(\.timeIntervalSinceReferenceDate.isFinite) else {
            throw DatabaseExecutionValidationError.invalidTimestamp("non-finite timestamp")
        }
        guard createdAt <= updatedAt else {
            throw DatabaseExecutionValidationError.invalidTimestamp("timestamp order")
        }
        guard additional.compactMap({ $0 }).allSatisfy({ $0 >= createdAt }) else {
            throw DatabaseExecutionValidationError.invalidTimestamp("timestamp order")
        }
    }

    private static func validate(
        _ identifier: DatabaseConnectionID,
        name: String
    ) throws {
        try validate(identifier.rawValue, name: name)
    }

    private static func validate(
        _ identifier: DatabaseSavedQueryID,
        name: String
    ) throws {
        try validate(identifier.rawValue, name: name)
    }

    private static func validate(_ identifier: UUID, name: String) throws {
        guard identifier != UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)) else {
            throw DatabaseExecutionValidationError.invalidIdentifier(name)
        }
    }

    private static func validateRequiredText(
        _ value: String,
        name: String,
        maximum: Int
    ) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DatabaseExecutionValidationError.invalidDefinition(name)
        }
        try validateByteLimit(value, name: name, maximum: maximum)
    }

    private static func validateOptionalText(
        _ value: String?,
        name: String,
        maximum: Int
    ) throws {
        guard let value else { return }
        try validateRequiredText(value, name: name, maximum: maximum)
    }

    private static func validateResponseSize<Value: Encodable>(
        _ value: Value,
        name: String
    ) throws {
        let encoded = try JSONEncoder().encode(value)
        guard encoded.count <= maximumPageBytes else {
            throw DatabaseExecutionValidationError.encodedSizeExceeded(
                name: name,
                actual: encoded.count,
                maximum: maximumPageBytes)
        }
    }

    private static func validateVersion(
        _ actual: Int,
        expected: Int,
        contract: String
    ) throws {
        guard actual == expected else {
            throw DatabaseExecutionValidationError.unsupportedVersion(
                contract: contract,
                expected: expected,
                actual: actual)
        }
    }

    private static func validateTarget(
        _ target: DatabaseTargetIdentifier,
        requiresObject: Bool
    ) throws {
        if requiresObject, target.object == nil {
            throw DatabaseExecutionValidationError.invalidTarget(
                "The operation requires a database object target.")
        }
        guard let object = target.object else { return }
        guard !object.path.isEmpty else {
            throw DatabaseExecutionValidationError.invalidTarget(
                "The target object path is empty.")
        }
        guard object.path.count <= maximumTargetPathSegments else {
            throw DatabaseExecutionValidationError.limitExceeded(
                name: "target path segments",
                actual: object.path.count,
                maximum: maximumTargetPathSegments)
        }
        for segment in object.path {
            guard !segment.isEmpty else {
                throw DatabaseExecutionValidationError.invalidTarget(
                    "The target object path contains an empty segment.")
            }
            try validateByteLimit(
                segment,
                name: "target path segment",
                maximum: maximumTargetSegmentBytes)
        }
    }

    private static func validatePageRequest(_ request: DatabasePageRequest) throws {
        var nodes = 0
        try validatePageRequest(request, nodes: &nodes)
    }

    private static func validatePageRequest(
        _ request: DatabasePageRequest,
        nodes: inout Int
    ) throws {
        guard request.sorts.count <= maximumSortCount else {
            throw DatabaseExecutionValidationError.limitExceeded(
                name: "sort fields",
                actual: request.sorts.count,
                maximum: maximumSortCount)
        }
        for sort in request.sorts {
            try validateFieldPath(sort.field)
        }
        if let projection = request.projection {
            guard projection.fields.count <= maximumFieldCount else {
                throw DatabaseExecutionValidationError.limitExceeded(
                    name: "projected fields",
                    actual: projection.fields.count,
                    maximum: maximumFieldCount)
            }
            for field in projection.fields {
                try validateFieldPath(field.path)
                if let alias = field.alias {
                    try validateByteLimit(
                        alias,
                        name: "projected field alias",
                        maximum: maximumTargetSegmentBytes)
                }
            }
        }
        if let filter = request.filter {
            try validateFilter(filter, nodes: &nodes)
        }
        if let continuation = request.continuation {
            try validateByteLimit(
                continuation.rawValue,
                name: "continuation token",
                maximum: maximumContinuationTokenBytes)
        }
    }

    private static func validateFieldPath(_ path: DatabaseFieldPath) throws {
        guard !path.segments.isEmpty else {
            throw DatabaseExecutionValidationError.invalidTarget("A field path is empty.")
        }
        guard path.segments.count <= maximumFieldPathSegments else {
            throw DatabaseExecutionValidationError.limitExceeded(
                name: "field path segments",
                actual: path.segments.count,
                maximum: maximumFieldPathSegments)
        }
        for segment in path.segments {
            guard !segment.isEmpty else {
                throw DatabaseExecutionValidationError.invalidTarget(
                    "A field path contains an empty segment.")
            }
            try validateByteLimit(
                segment,
                name: "field path segment",
                maximum: maximumTargetSegmentBytes)
        }
    }

    private static func validateFilter(
        _ filter: DatabaseFilter,
        nodes: inout Int
    ) throws {
        var pending = [(filter, 1)]
        while let (current, depth) = pending.popLast() {
            try consumeNode(depth: depth, nodes: &nodes)
            switch current {
            case let .predicate(predicate):
                try validateFieldPath(predicate.field)
                for value in predicate.values {
                    try validateValue(value, nodes: &nodes)
                }
            case let .all(children), let .any(children):
                pending.append(contentsOf: children.map { ($0, depth + 1) })
            case let .not(child):
                pending.append((child, depth + 1))
            }
        }
    }

    private static func validateValue(
        _ value: DatabaseValue,
        nodes: inout Int
    ) throws {
        var pending = [(value, 1)]
        while let (current, depth) = pending.popLast() {
            try consumeNode(depth: depth, nodes: &nodes)
            switch current {
            case let .array(values):
                pending.append(contentsOf: values.map { ($0, depth + 1) })
            case let .object(fields):
                for field in fields {
                    guard !field.name.isEmpty else {
                        throw DatabaseExecutionValidationError.invalidTarget(
                            "A database object value contains an empty field name.")
                    }
                    try validateByteLimit(
                        field.name,
                        name: "database object field name",
                        maximum: maximumTargetSegmentBytes)
                }
                pending.append(contentsOf: fields.map { ($0.value, depth + 1) })
            case .missing, .null, .boolean, .signedInteger, .unsignedInteger, .decimal,
                .floatingPoint, .string, .binary, .date, .time, .timestamp, .uuid,
                .productSpecific:
                break
            }
        }
    }

    private static func consumeNode(depth: Int, nodes: inout Int) throws {
        guard depth <= maximumFilterDepth else {
            throw DatabaseExecutionValidationError.limitExceeded(
                name: "input depth",
                actual: depth,
                maximum: maximumFilterDepth)
        }
        nodes += 1
        guard nodes <= maximumInputNodes else {
            throw DatabaseExecutionValidationError.limitExceeded(
                name: "input nodes",
                actual: nodes,
                maximum: maximumInputNodes)
        }
    }

    private static func validateEncodedSize<Value: Encodable>(
        _ value: Value,
        name: String
    ) throws {
        let encoded = try JSONEncoder().encode(value)
        guard encoded.count <= maximumRequestBytes else {
            throw DatabaseExecutionValidationError.encodedSizeExceeded(
                name: name,
                actual: encoded.count,
                maximum: maximumRequestBytes)
        }
    }

    private static func validateByteLimit(
        _ value: String,
        name: String,
        maximum: Int
    ) throws {
        let bytes = value.utf8.count
        guard bytes <= maximum else {
            throw DatabaseExecutionValidationError.encodedSizeExceeded(
                name: name,
                actual: bytes,
                maximum: maximum)
        }
    }
}
