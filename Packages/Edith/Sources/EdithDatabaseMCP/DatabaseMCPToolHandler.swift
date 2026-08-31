import EdithDatabase
import Foundation
import MCP

public struct DatabaseMCPToolHandler: Sendable {
    private static let maximumSearchCharacters = 256
    private static let maximumTextCharacters = 2_048
    private static let maximumConnections = 100
    private static let maximumCapabilities = 256
    private static let maximumCollectionItems = 64
    private static let maximumPageSize = 500
    private static let maximumContinuationCharacters = 32_768
    private static let maximumQueryCharacters = 262_144
    private static let maximumDocumentBytes = 1_048_576

    private let sender: any DatabaseBrokerCommandSending
    private let makeOperationID: @Sendable () -> DatabaseOperationID

    public init(
        sender: any DatabaseBrokerCommandSending = DatabaseBrokerCommandClient(),
        makeOperationID: @escaping @Sendable () -> DatabaseOperationID = {
            DatabaseOperationID()
        }
    ) {
        self.sender = sender
        self.makeOperationID = makeOperationID
    }

    public func callTool(_ parameters: CallTool.Parameters) async -> CallTool.Result {
        do {
            guard let tool = DatabaseMCPToolName(rawValue: parameters.name) else {
                return Self.failure(
                    category: "unsupported",
                    message: "Unknown database tool: \(Self.bounded(parameters.name)).")
            }
            switch tool {
            case .connections:
                return try await connections(arguments: parameters.arguments ?? [:])
            case .capabilities:
                return try await capabilities(arguments: parameters.arguments ?? [:])
            case .browse:
                return try await browse(arguments: parameters.arguments ?? [:])
            case .query:
                return try await query(arguments: parameters.arguments ?? [:])
            case .operations:
                return try await operations(arguments: parameters.arguments ?? [:])
            case .cancelOperation:
                return try await cancelOperation(arguments: parameters.arguments ?? [:])
            case .testConnection:
                return try await testConnection(arguments: parameters.arguments ?? [:])
            case .session:
                return try await session(arguments: parameters.arguments ?? [:])
            case .keyMutation:
                return try await keyMutation(arguments: parameters.arguments ?? [:])
            case .documentMutation:
                return try await documentMutation(arguments: parameters.arguments ?? [:])
            }
        } catch is CancellationError {
            return Self.failure(
                category: "cancelled", message: "The database request was cancelled.")
        } catch let error as DatabaseMCPInputError {
            return Self.failure(category: "invalidRequest", message: error.message)
        } catch let error as DatabaseBrokerCommandClientError {
            return Self.transportFailure(error)
        } catch {
            return Self.failure(
                category: "internalFailure",
                message: "The database tool could not complete the request.")
        }
    }

    private func connections(arguments: [String: Value]) async throws -> CallTool.Result {
        try Self.rejectUnknown(arguments, allowed: ["action", "connection_id", "search"])
        let action = try Self.requiredString("action", in: arguments)
        switch action {
        case "list":
            let search = try Self.optionalString("search", in: arguments)
            if let search, search.count > Self.maximumSearchCharacters {
                throw DatabaseMCPInputError(
                    message: "search must not exceed \(Self.maximumSearchCharacters) characters.")
            }
            let response = try await sender.send(
                .connectionList(
                    DatabaseConnectionListRequest(
                        search: DatabaseConnectionSearch(
                            text: search,
                            limit: Self.maximumConnections))))
            guard let result = response.connectionListResult else {
                return Self.responseKindFailure(
                    expected: DatabaseBrokerCommandKind.connectionList,
                    actual: response.kind)
            }
            return Self.render(result) { payload in
                .object([
                    "action": "list",
                    "connections": .array(
                        payload.connections.prefix(Self.maximumConnections).map(Self.connection)),
                    "returned_count": .int(
                        min(payload.connections.count, Self.maximumConnections)),
                ])
            }
        case "get":
            let connectionID = try Self.connectionID(in: arguments)
            let response = try await sender.send(
                .connectionGet(DatabaseConnectionGetRequest(connectionID: connectionID)))
            guard let result = response.connectionGetResult else {
                return Self.responseKindFailure(
                    expected: DatabaseBrokerCommandKind.connectionGet,
                    actual: response.kind)
            }
            return Self.render(result) { payload in
                .object([
                    "action": "get",
                    "connection": payload.connection.map(Self.connection) ?? .null,
                ])
            }
        default:
            throw DatabaseMCPInputError(message: "action must be list or get.")
        }
    }

    private func capabilities(arguments: [String: Value]) async throws -> CallTool.Result {
        try Self.rejectUnknown(arguments, allowed: ["connection_id", "refresh"])
        let connectionID = try Self.connectionID(in: arguments)
        let refresh = try Self.optionalBool("refresh", in: arguments) ?? false
        let response = try await sender.send(
            .capabilities(
                DatabaseCapabilitiesRequest(
                    connectionID: connectionID,
                    resolution: refresh ? .refresh : .cachedOrDiscover,
                    operation: DatabaseOperationContext(operationID: makeOperationID()))))
        guard let result = response.capabilitiesResult else {
            return Self.responseKindFailure(
                expected: DatabaseBrokerCommandKind.capabilities,
                actual: response.kind)
        }
        return Self.render(result) { payload in
            .object([
                "connection_id": Self.uuid(connectionID.rawValue),
                "source": .string(payload.source.rawValue),
                "report": Self.capabilityReport(payload.report),
            ])
        }
    }

    private func browse(arguments: [String: Value]) async throws -> CallTool.Result {
        try Self.rejectUnknown(
            arguments,
            allowed: [
                "connection_id", "object_kind", "object_path", "page_size", "continuation",
                "timeout_ms",
            ])
        let target = try Self.target(in: arguments, requiresObject: false)
        let response = try await sender.send(
            .browse(
                DatabaseBrowseRequest(
                    target: target,
                    page: try Self.pageRequest(in: arguments),
                    operation: try operationContext(arguments))))
        guard let result = response.browseResult else {
            return Self.responseKindFailure(expected: .browse, actual: response.kind)
        }
        return Self.render(result) { payload in
            .object([
                "connection_id": Self.uuid(target.connectionID.rawValue),
                "page": Self.page(payload.page),
            ])
        }
    }

    private func query(arguments: [String: Value]) async throws -> CallTool.Result {
        try Self.rejectUnknown(
            arguments,
            allowed: [
                "connection_id", "object_kind", "object_path", "page_size", "continuation",
                "timeout_ms", "language", "command",
            ])
        let target = try Self.target(in: arguments, requiresObject: false)
        let command = try Self.requiredString("command", in: arguments)
        guard command.count <= Self.maximumQueryCharacters else {
            throw DatabaseMCPInputError(
                message: "command must not exceed \(Self.maximumQueryCharacters) characters.")
        }
        let language = try Self.queryLanguage(in: arguments)
        let response = try await sender.send(
            .query(
                DatabaseQueryRequest(
                    target: target,
                    language: language,
                    command: command,
                    page: try Self.pageRequest(in: arguments),
                    operation: try operationContext(arguments))))
        guard let result = response.queryResult else {
            return Self.responseKindFailure(expected: .query, actual: response.kind)
        }
        return Self.render(result) { payload in
            .object([
                "connection_id": Self.uuid(target.connectionID.rawValue),
                "page": Self.page(payload.page),
            ])
        }
    }

    private func keyMutation(arguments: [String: Value]) async throws -> CallTool.Result {
        try Self.rejectUnknown(
            arguments,
            allowed: [
                "mode", "connection_id", "product", "action", "logical_database", "key",
                "value", "ttl_ms", "confirmation_token", "confirmation_text", "timeout_ms",
            ])
        let request = try Self.keyMutationRequest(in: arguments)
        return try await mutation(arguments: arguments, request: request)
    }

    private func documentMutation(arguments: [String: Value]) async throws -> CallTool.Result {
        try Self.rejectUnknown(
            arguments,
            allowed: [
                "mode", "connection_id", "product", "action", "database", "collection",
                "index", "document", "document_id", "id_kind", "sequence_number",
                "primary_term", "confirmation_token", "confirmation_text", "timeout_ms",
            ])
        let request = try Self.documentMutationRequest(in: arguments)
        return try await mutation(arguments: arguments, request: request)
    }

    private func mutation(
        arguments: [String: Value],
        request mutation: DatabaseDestructiveRequest
    ) async throws -> CallTool.Result {
        let mode = try Self.requiredString("mode", in: arguments)
        let operation = try operationContext(arguments)
        switch mode {
        case "preview":
            guard arguments["confirmation_token"] == nil,
                arguments["confirmation_text"] == nil
            else {
                throw DatabaseMCPInputError(
                    message: "preview does not accept confirmation_token or confirmation_text.")
            }
            let response = try await sender.send(
                .mutationPreview(
                    DatabaseMutationPreviewRequest(
                        mutation: mutation,
                        operation: operation)))
            guard let result = response.mutationPreviewResult else {
                return Self.responseKindFailure(expected: .mutationPreview, actual: response.kind)
            }
            return Self.render(result) { payload in
                let preview = payload.preview
                return .object([
                    "mode": "preview",
                    "action": .string(preview.effect.action.rawValue),
                    "scope": .string(preview.effect.scope.rawValue),
                    "impact": .object([
                        "value": preview.effect.impact.count.value.map(Self.unsigned) ?? .null,
                        "accuracy": .string(preview.effect.impact.count.accuracy.rawValue),
                        "description": .string(Self.bounded(preview.effect.impact.description)),
                    ]),
                    "rollback": .string(preview.effect.rollbackAvailability.rawValue),
                    "warnings": .array(preview.warnings.map(Self.warning)),
                    "confirmation_token": .string(preview.token.rawValue),
                    "confirmation_text": .string(preview.requiredConfirmation.text),
                    "expires_at": Self.date(preview.expiresAt),
                    "operation_id": Self.uuid(operation.operationID.rawValue),
                ])
            }
        case "apply":
            let token = try Self.requiredString("confirmation_token", in: arguments)
            let confirmationText = try Self.requiredString("confirmation_text", in: arguments)
            let response = try await sender.send(
                .mutationApply(
                    DatabaseMutationApplyRequest(
                        mutation: mutation,
                        token: DatabaseConfirmationToken(rawValue: token),
                        confirmationText: confirmationText,
                        operation: operation)))
            guard let result = response.mutationApplyResult else {
                return Self.responseKindFailure(expected: .mutationApply, actual: response.kind)
            }
            return Self.render(result) { payload in
                .object([
                    "mode": "apply",
                    "disposition": .string(payload.disposition.rawValue),
                    "effect": .string(payload.effect.rawValue),
                    "affected_records": .object([
                        "value": payload.affectedRecords.value.map(Self.unsigned) ?? .null,
                        "accuracy": .string(payload.affectedRecords.accuracy.rawValue),
                    ]),
                    "operation_id": Self.uuid(operation.operationID.rawValue),
                ])
            }
        default:
            throw DatabaseMCPInputError(message: "mode must be preview or apply.")
        }
    }

    private func operationContext(
        _ arguments: [String: Value]
    ) throws -> DatabaseOperationContext {
        let timeout = try Self.optionalInt("timeout_ms", in: arguments)
        if let timeout, !(1...86_400_000).contains(timeout) {
            throw DatabaseMCPInputError(
                message: "timeout_ms must be between 1 and 86400000.")
        }
        return DatabaseOperationContext(
            operationID: makeOperationID(),
            deadline: timeout.map { Date().addingTimeInterval(Double($0) / 1_000) })
    }

    private func operations(arguments: [String: Value]) async throws -> CallTool.Result {
        try Self.rejectUnknown(
            arguments,
            allowed: [
                "action", "operation_id", "connection_id", "states", "kinds", "before", "limit",
            ])
        let action = try Self.requiredString("action", in: arguments)
        switch action {
        case "list":
            let limit = try Self.optionalInt("limit", in: arguments) ?? 200
            guard (1...1_000).contains(limit) else {
                throw DatabaseMCPInputError(message: "limit must be between 1 and 1000.")
            }
            let connectionID = try Self.optionalConnectionID(in: arguments)
            let search = DatabaseOperationHistorySearch(
                connectionID: connectionID,
                states: try Self.operationStates(in: arguments),
                kinds: try Self.operationKinds(in: arguments),
                before: try Self.optionalDate("before", in: arguments),
                limit: limit)
            let response = try await sender.send(
                .operationList(DatabaseOperationListRequest(search: search)))
            guard let result = response.operationListResult else {
                return Self.responseKindFailure(expected: .operationList, actual: response.kind)
            }
            return Self.render(result) { payload in
                .object([
                    "action": "list",
                    "operations": .array(payload.operations.prefix(limit).map(Self.operation)),
                ])
            }
        case "get":
            let operationID = try Self.operationID(in: arguments)
            let response = try await sender.send(
                .operationGet(DatabaseOperationGetRequest(operationID: operationID)))
            guard let result = response.operationGetResult else {
                return Self.responseKindFailure(expected: .operationGet, actual: response.kind)
            }
            return Self.render(result) { payload in
                .object([
                    "action": "get",
                    "operation": payload.operation.map(Self.operation) ?? .null,
                ])
            }
        default:
            throw DatabaseMCPInputError(message: "action must be list or get.")
        }
    }

    private func cancelOperation(arguments: [String: Value]) async throws -> CallTool.Result {
        try Self.rejectUnknown(arguments, allowed: ["operation_id"])
        let operationID = try Self.operationID(in: arguments)
        let response = try await sender.send(
            .operationCancel(DatabaseOperationCancelRequest(operationID: operationID)))
        guard let result = response.operationCancelResult else {
            return Self.responseKindFailure(expected: .operationCancel, actual: response.kind)
        }
        return Self.render(result) { payload in
            .object([
                "operation_id": Self.uuid(payload.operationID.rawValue),
                "disposition": .string(payload.disposition.rawValue),
                "cancellation_support": .string(payload.cancellationSupport.rawValue),
                "operation": payload.operation.map(Self.operation) ?? .null,
            ])
        }
    }

    private func testConnection(arguments: [String: Value]) async throws -> CallTool.Result {
        try Self.rejectUnknown(arguments, allowed: ["connection_id", "timeout_ms"])
        let connectionID = try Self.connectionID(in: arguments)
        let getResponse = try await sender.send(
            .connectionGet(DatabaseConnectionGetRequest(connectionID: connectionID)))
        guard let getResult = getResponse.connectionGetResult else {
            return Self.responseKindFailure(expected: .connectionGet, actual: getResponse.kind)
        }
        guard let getPayload = getResult.payload else {
            return Self.failure(
                envelope: getResult.error
                    ?? DatabaseErrorEnvelope(
                        category: .internalFailure,
                        message: "The connection lookup did not contain a payload."),
                metadata: getResult.metadata)
        }
        guard let definition = getPayload.connection else {
            return Self.failure(
                category: "notFound", message: "The saved database connection was not found.")
        }
        let operation = try operationContext(arguments)
        let testResponse = try await sender.send(
            .connectionTest(
                DatabaseConnectionTestRequest(
                    connection: definition,
                    operation: operation)))
        guard let result = testResponse.connectionTestResult else {
            return Self.responseKindFailure(expected: .connectionTest, actual: testResponse.kind)
        }
        return Self.render(result) { payload in
            .object([
                "connection_id": Self.uuid(connectionID.rawValue),
                "display_name": .string(Self.bounded(payload.connection.displayName)),
                "product": .string(payload.productIdentity.product.rawValue),
                "version": Self.optional(payload.productIdentity.version?.string),
                "latency_ms": Self.unsigned(payload.latencyMilliseconds),
                "tested_at": Self.date(payload.testedAt),
                "operation_id": Self.uuid(operation.operationID.rawValue),
            ])
        }
    }

    private func session(arguments: [String: Value]) async throws -> CallTool.Result {
        try Self.rejectUnknown(arguments, allowed: ["action", "connection_id", "timeout_ms"])
        let action = try Self.requiredString("action", in: arguments)
        let connectionID = try Self.connectionID(in: arguments)
        let operation = try operationContext(arguments)
        switch action {
        case "connect":
            let response = try await sender.send(
                .connect(
                    DatabaseConnectRequest(
                        connectionID: connectionID,
                        operation: operation)))
            guard let result = response.connectResult else {
                return Self.responseKindFailure(expected: .connect, actual: response.kind)
            }
            return Self.render(result) { payload in
                .object([
                    "action": "connect",
                    "connection_id": Self.uuid(connectionID.rawValue),
                    "display_name": .string(Self.bounded(payload.connection.displayName)),
                    "product": .string(payload.productIdentity.product.rawValue),
                    "version": Self.optional(payload.productIdentity.version?.string),
                    "disconnected": .null,
                    "completed_at": Self.date(payload.connectedAt),
                    "operation_id": Self.uuid(operation.operationID.rawValue),
                ])
            }
        case "disconnect":
            let response = try await sender.send(
                .disconnect(
                    DatabaseDisconnectRequest(
                        connectionID: connectionID,
                        operation: operation)))
            guard let result = response.disconnectResult else {
                return Self.responseKindFailure(expected: .disconnect, actual: response.kind)
            }
            return Self.render(result) { payload in
                .object([
                    "action": "disconnect",
                    "connection_id": Self.uuid(connectionID.rawValue),
                    "display_name": .string(Self.bounded(payload.connection.displayName)),
                    "product": .null,
                    "version": .null,
                    "disconnected": .bool(payload.disconnected),
                    "completed_at": Self.date(payload.disconnectedAt),
                    "operation_id": Self.uuid(operation.operationID.rawValue),
                ])
            }
        default:
            throw DatabaseMCPInputError(message: "action must be connect or disconnect.")
        }
    }

    private static func render<Payload: Sendable>(
        _ result: DatabaseCommandResult<Payload>,
        payload: (Payload) -> Value
    ) -> CallTool.Result {
        guard let value = result.payload else {
            return failure(
                envelope: result.error
                    ?? DatabaseErrorEnvelope(
                        category: .internalFailure,
                        message: "The database response did not contain a payload."),
                metadata: result.metadata)
        }
        var fields: [String: Value] = [
            "status": .string(result.status.rawValue),
            "data": payload(value),
            "metadata": metadata(result.metadata),
        ]
        if let error = result.error {
            fields["error"] = errorValue(error)
        }
        return response(.object(fields), isError: false)
    }

    private static func failure(
        envelope: DatabaseErrorEnvelope,
        metadata: DatabaseResultMetadata
    ) -> CallTool.Result {
        response(
            .object([
                "status": "failed",
                "error": errorValue(envelope),
                "metadata": Self.metadata(metadata),
            ]),
            isError: true)
    }

    private static func failure(category: String, message: String) -> CallTool.Result {
        response(
            .object([
                "status": "failed",
                "error": .object([
                    "category": .string(category),
                    "message": .string(bounded(message)),
                ]),
            ]),
            isError: true)
    }

    private static func transportFailure(
        _ error: DatabaseBrokerCommandClientError
    ) -> CallTool.Result {
        switch error {
        case .invalidRequest:
            failure(
                category: "invalidRequest", message: "The database service rejected the request.")
        case .timedOut:
            failure(category: "timeout", message: "The database service request timed out.")
        case .unavailable:
            failure(category: "network", message: "The database service is unavailable.")
        case .unsafePeer:
            failure(
                category: "authenticationFailed",
                message: "The database service could not verify the local app.")
        case .outcomeUnknown:
            failure(
                category: "network",
                message: "The database service could not confirm the request outcome.")
        }
    }

    private static func responseKindFailure(
        expected: DatabaseBrokerCommandKind,
        actual: DatabaseBrokerCommandKind
    ) -> CallTool.Result {
        failure(
            category: "decoding",
            message: "Expected \(expected.rawValue) but received \(actual.rawValue).")
    }

    private static func response(_ value: Value, isError: Bool) -> CallTool.Result {
        CallTool.Result(
            content: [
                .text(text: json(value), annotations: nil, _meta: nil)
            ],
            structuredContent: Optional<Value>.some(value),
            isError: isError)
    }

    private static func json(_ value: Value) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard
            let data = try? encoder.encode(value),
            let text = String(data: data, encoding: .utf8)
        else {
            return "{\"status\":\"failed\"}"
        }
        return text
    }

    private static func connection(_ value: DatabaseConnectionDefinition) -> Value {
        .object([
            "id": uuid(value.id.rawValue),
            "display_name": .string(bounded(value.displayName)),
            "product": .string(value.productHint.rawValue),
            "family": .string(value.productHint.family.rawValue),
            "environment": .object([
                "kind": .string(value.environment.kind.rawValue),
                "label": .string(bounded(value.environment.label)),
                "protection": .string(value.environment.protection.rawValue),
            ]),
            "namespace_defaults": .object([
                "catalog": optional(value.namespaces.catalog),
                "schema": optional(value.namespaces.schema),
                "database": optional(value.namespaces.database),
                "logical_database": optional(value.namespaces.logicalDatabase),
            ]),
            "read_only_policy": .string(value.readOnlyPolicy.rawValue),
            "production_policy": .string(value.productionPolicy.rawValue),
            "group": optional(value.group),
            "tags": .array(
                value.tags.prefix(Self.maximumCollectionItems).map {
                    .string(bounded($0))
                }),
            "color": optional(value.color),
            "is_favorite": .bool(value.isFavorite),
            "created_at": date(value.createdAt),
            "updated_at": date(value.updatedAt),
            "last_tested_at": optionalDate(value.lastTestedAt),
            "last_used_at": optionalDate(value.lastUsedAt),
        ])
    }

    private static func capabilityReport(_ value: DatabaseCapabilityReport) -> Value {
        .object([
            "product": productIdentity(value.productIdentity),
            "capabilities": .array(
                value.capabilities.prefix(maximumCapabilities).map(capability)),
            "permissions": .array(
                value.permissions.prefix(maximumCollectionItems).map(permission)),
            "paging_modes": strings(value.pagingModes.map(\.rawValue)),
            "mutation_modes": strings(value.mutationModes.map(\.rawValue)),
            "transaction_modes": strings(value.transactionModes.map(\.rawValue)),
            "cancellation_modes": strings(value.cancellationModes.map(\.rawValue)),
            "import_formats": strings(value.importFormats.map(\.rawValue)),
            "export_formats": strings(value.exportFormats.map(\.rawValue)),
            "explain_modes": strings(value.explainModes.map(\.rawValue)),
            "safety_limitations": strings(value.safetyLimitations),
            "discovered_at": date(value.discoveredAt),
            "expires_at": optionalDate(value.expiresAt),
        ])
    }

    private static func productIdentity(_ value: DatabaseProductIdentity) -> Value {
        .object([
            "product": .string(value.product.rawValue),
            "family": .string(value.product.family.rawValue),
            "version": value.version.map { version in
                .object([
                    "string": .string(bounded(version.string)),
                    "major": optionalInt(version.major),
                    "minor": optionalInt(version.minor),
                    "patch": optionalInt(version.patch),
                ])
            } ?? .null,
            "distribution": optional(value.distribution),
            "topology": .object([
                "kind": .string(value.topology.kind.rawValue),
                "name": optional(value.topology.name),
                "local_role": optional(value.topology.localRole),
                "node_count": optionalInt(value.topology.nodeCount),
                "replica_count": optionalInt(value.topology.replicaCount),
                "shard_count": optionalInt(value.topology.shardCount),
                "attributes": attributes(value.topology.attributes),
            ]),
            "modules": extensions(value.modules),
            "plugins": extensions(value.plugins),
            "compatibility_notes": strings(value.compatibilityNotes),
        ])
    }

    private static func capability(_ value: DatabaseCapabilityStatus) -> Value {
        .object([
            "id": .string(bounded(value.id.rawValue)),
            "requirement": .string(value.requirement.rawValue),
            "availability": .string(value.availability.rawValue),
            "reason": value.reason.map { reason in
                .object([
                    "category": .string(reason.category.rawValue),
                    "message": .string(bounded(reason.message)),
                    "required_version": optional(reason.requiredVersion),
                    "required_topology": reason.requiredTopology.map {
                        .string($0.rawValue)
                    } ?? .null,
                    "missing_permissions": strings(reason.missingPermissions),
                    "required_extension": optional(reason.requiredExtension),
                    "constraints": attributes(reason.constraints),
                ])
            } ?? .null,
            "limits": .array(
                value.limits.prefix(maximumCollectionItems).map { limit in
                    .object([
                        "name": .string(bounded(limit.name)),
                        "value": unsigned(limit.value),
                        "unit": optional(limit.unit),
                    ])
                }),
            "attributes": attributes(value.attributes),
        ])
    }

    private static func permission(_ value: DatabasePermissionStatus) -> Value {
        .object([
            "name": .string(bounded(value.name)),
            "granted": value.granted.map(Value.bool) ?? .null,
            "scope": optional(value.scope),
        ])
    }

    private static func page(_ value: DatabasePage<DatabaseRecord>) -> Value {
        .object([
            "records": .array(value.records.prefix(maximumPageSize).map(record)),
            "fields": .array(value.fields.prefix(maximumCapabilities).map(field)),
            "next_continuation": optional(value.nextContinuation?.rawValue),
            "metadata": pageMetadata(value.metadata),
        ])
    }

    private static func record(_ value: DatabaseRecord) -> Value {
        .object([
            "identity": value.identity.map(recordIdentity) ?? .null,
            "fields": .array(
                value.fields.prefix(maximumCapabilities).map {
                    .object([
                        "name": .string(bounded($0.name)),
                        "value": databaseValue($0.value),
                    ])
                }),
            "metadata": .array(
                value.metadata.prefix(maximumCollectionItems).map {
                    .object([
                        "name": .string(bounded($0.name)),
                        "value": .string(bounded($0.value)),
                    ])
                }),
        ])
    }

    private static func recordIdentity(_ value: DatabaseRecordIdentity) -> Value {
        .object([
            "kind": .string(value.kind.rawValue),
            "components": .array(
                value.components.prefix(maximumCollectionItems).map(identityComponent)),
            "concurrency_tokens": .array(
                value.concurrencyTokens.prefix(maximumCollectionItems).map(identityComponent)),
        ])
    }

    private static func identityComponent(_ value: DatabaseIdentityComponent) -> Value {
        .object([
            "name": .string(bounded(value.name)),
            "value": databaseValue(value.value),
        ])
    }

    private static func field(_ value: DatabaseFieldDescriptor) -> Value {
        .object([
            "path": .array(value.path.segments.map { .string(bounded($0)) }),
            "display_name": .string(bounded(value.displayName)),
            "type_name": .string(bounded(value.typeName)),
            "nullable": .bool(value.isNullable),
            "sortable": .bool(value.isSortable),
            "filterable": .bool(value.isFilterable),
        ])
    }

    private static func pageMetadata(_ value: DatabasePageMetadata) -> Value {
        .object([
            "completeness": .object([
                "state": .string(value.completeness.state.rawValue),
                "reason": optional(value.completeness.reason),
            ]),
            "count": .object([
                "value": value.count.value.map(unsigned) ?? .null,
                "accuracy": .string(value.count.accuracy.rawValue),
            ]),
            "timing": value.timing.map {
                .object([
                    "duration_ms": unsigned($0.durationMilliseconds),
                    "server_duration_ms": $0.serverDurationMilliseconds.map(unsigned) ?? .null,
                ])
            } ?? .null,
            "bytes_received": value.bytesReceived.map(unsigned) ?? .null,
            "warnings": .array(
                value.warnings.prefix(maximumCollectionItems).map(warning)),
            "partial_failures": .array(
                value.partialFailures.prefix(maximumCollectionItems).map(partialFailure)),
        ])
    }

    private static func databaseValue(_ value: DatabaseValue) -> Value {
        switch value {
        case .missing:
            return .object(["kind": "missing"])
        case .null:
            return .null
        case .boolean(let flag):
            return .bool(flag)
        case .signedInteger(let number):
            return Int(exactly: number).map(Value.int) ?? .string(String(number))
        case .unsignedInteger(let number):
            return unsigned(number)
        case .decimal(let number):
            return .object(["kind": "decimal", "value": .string(number.rawValue)])
        case .floatingPoint(let number):
            return number.isFinite ? .double(number) : .null
        case .string(let text):
            return boundedValue(text)
        case .binary(let binary):
            let available = binary.availableBytes.prefix(4_096)
            return .object([
                "kind": "binary",
                "byte_count": unsigned(binary.byteCount),
                "base64": .string(Data(available).base64EncodedString()),
                "complete": .bool(binary.isComplete),
                "truncated": .bool(binary.availableBytes.count > available.count),
            ])
        case .date(let date):
            return .object(["kind": "date", "value": .string(bounded(date.text))])
        case .time(let time):
            return .object(["kind": "time", "value": .string(bounded(time.text))])
        case .timestamp(let timestamp):
            return .object(["kind": "timestamp", "value": .string(bounded(timestamp.text))])
        case .uuid(let identifier):
            return uuid(identifier)
        case .array(let values):
            return .object([
                "kind": "array",
                "values": .array(values.prefix(maximumCollectionItems).map(databaseValue)),
                "truncated": .bool(values.count > maximumCollectionItems),
            ])
        case .object(let fields):
            return .object([
                "kind": "object",
                "fields": .array(
                    fields.prefix(maximumCollectionItems).map {
                        .object([
                            "name": .string(bounded($0.name)),
                            "value": databaseValue($0.value),
                        ])
                    }),
                "truncated": .bool(fields.count > maximumCollectionItems),
            ])
        case .productSpecific(let product):
            return .object([
                "kind": "productSpecific",
                "product": optional(product.product?.rawValue),
                "type_name": .string(bounded(product.typeName)),
                "text": product.textRepresentation.map(boundedValue) ?? .null,
                "binary_bytes": product.binaryRepresentation.map { .int($0.count) } ?? .null,
            ])
        }
    }

    private static func boundedValue(_ value: String) -> Value {
        guard value.count > maximumTextCharacters else { return .string(value) }
        return .object([
            "kind": "string",
            "value": .string(bounded(value)),
            "characters": .int(value.count),
            "truncated": true,
        ])
    }

    private static func metadata(_ value: DatabaseResultMetadata) -> Value {
        .object([
            "operation": value.operation.map(operation) ?? .null,
            "completeness": .object([
                "state": .string(value.completeness.state.rawValue),
                "reason": optional(value.completeness.reason),
            ]),
            "count": value.count.map { count in
                .object([
                    "value": count.value.map(unsigned) ?? .null,
                    "accuracy": .string(count.accuracy.rawValue),
                ])
            } ?? .null,
            "warnings": .array(
                value.warnings.prefix(maximumCollectionItems).map(warning)),
            "partial_failures": .array(
                value.partialFailures.prefix(maximumCollectionItems).map(partialFailure)),
        ])
    }

    private static func operation(_ value: DatabaseOperationRecordSummary) -> Value {
        .object([
            "id": uuid(value.id.rawValue),
            "kind": .string(bounded(value.kind.rawValue)),
            "state": .string(value.state.rawValue),
            "connection_id": uuid(value.connection.id.rawValue),
            "connection_name": .string(bounded(value.connection.displayName)),
            "target": value.target.map(targetValue) ?? .null,
            "started_at": optionalDate(value.startedAt),
            "finished_at": optionalDate(value.finishedAt),
            "deadline": optionalDate(value.deadline),
            "progress": value.progress.map { progress in
                .object([
                    "kind": .string(progress.kind.rawValue),
                    "completed": progress.completed.map(unsigned) ?? .null,
                    "total": progress.total.map(unsigned) ?? .null,
                    "unit": optional(progress.unit?.rawValue),
                    "message": optional(progress.message),
                ])
            } ?? .null,
            "cancellation_support": .string(value.cancellationSupport.rawValue),
            "retry_classification": .string(value.retryClassification.rawValue),
            "page_count": unsigned(value.pageCount),
            "record_count": unsigned(value.recordCount),
            "byte_count": unsigned(value.byteCount),
            "warnings": .array(
                value.warnings.prefix(maximumCollectionItems).map(warning)),
            "partial_failures": .array(
                value.partialFailures.prefix(maximumCollectionItems).map(partialFailure)),
            "error": value.error.map(errorValue) ?? .null,
        ])
    }

    private static func targetValue(_ value: DatabaseTargetIdentifier) -> Value {
        .object([
            "connection_id": uuid(value.connectionID.rawValue),
            "object": value.object.map { object in
                .object([
                    "kind": .string(object.kind.rawValue),
                    "path": .array(object.path.map { .string(bounded($0)) }),
                ])
            } ?? .null,
            "record": value.record.map(recordIdentity) ?? .null,
        ])
    }

    private static func warning(_ value: DatabaseWarning) -> Value {
        .object([
            "code": .string(bounded(value.code)),
            "message": .string(bounded(value.message)),
            "severity": .string(value.severity.rawValue),
        ])
    }

    private static func partialFailure(_ value: DatabasePartialFailure) -> Value {
        .object([
            "item_index": value.itemIndex.map(unsigned) ?? .null,
            "item_identifier": optional(value.itemIdentifier),
            "error": errorValue(value.error),
        ])
    }

    private static func errorValue(_ value: DatabaseErrorEnvelope) -> Value {
        .object([
            "category": .string(value.category.rawValue),
            "message": .string(bounded(value.message)),
            "product_code": optional(value.productCode),
            "retry": .object([
                "action": .string(value.retry.action.rawValue),
                "after_milliseconds": value.retry.afterMilliseconds.map(unsigned) ?? .null,
                "message": optional(value.retry.message),
            ]),
            "partial_result": value.partialResult.map { partial in
                .object([
                    "state": .string(partial.state.rawValue),
                    "reason": optional(partial.reason),
                ])
            } ?? .null,
            "details": .array(
                value.details.prefix(maximumCollectionItems).map { detail in
                    .object([
                        "name": .string(bounded(detail.name)),
                        "value": .string(bounded(detail.value)),
                    ])
                }),
        ])
    }

    private static func attributes(_ values: [DatabaseStringAttribute]) -> Value {
        .array(
            values.prefix(maximumCollectionItems).map { value in
                .object([
                    "name": .string(bounded(value.name)),
                    "value": .string(bounded(value.value)),
                ])
            })
    }

    private static func extensions(_ values: [DatabaseExtensionIdentity]) -> Value {
        .array(
            values.prefix(maximumCollectionItems).map { value in
                .object([
                    "name": .string(bounded(value.name)),
                    "version": optional(value.version),
                ])
            })
    }

    private static func strings(_ values: [String]) -> Value {
        .array(
            values.prefix(maximumCollectionItems).map {
                .string(bounded($0))
            })
    }

    private static func requiredString(
        _ key: String,
        in arguments: [String: Value]
    ) throws -> String {
        guard let value = arguments[key]?.stringValue, !value.isEmpty else {
            throw DatabaseMCPInputError(message: "\(key) is required and must be a string.")
        }
        return value
    }

    private static func optionalString(
        _ key: String,
        in arguments: [String: Value]
    ) throws -> String? {
        guard let value = arguments[key] else { return nil }
        guard let string = value.stringValue else {
            throw DatabaseMCPInputError(message: "\(key) must be a string.")
        }
        return string.isEmpty ? nil : string
    }

    private static func optionalBool(
        _ key: String,
        in arguments: [String: Value]
    ) throws -> Bool? {
        guard let value = arguments[key] else { return nil }
        guard let boolean = value.boolValue else {
            throw DatabaseMCPInputError(message: "\(key) must be a boolean.")
        }
        return boolean
    }

    private static func optionalInt(
        _ key: String,
        in arguments: [String: Value]
    ) throws -> Int? {
        guard let value = arguments[key] else { return nil }
        guard let integer = value.intValue else {
            throw DatabaseMCPInputError(message: "\(key) must be an integer.")
        }
        return integer
    }

    private static func stringArray(
        _ key: String,
        in arguments: [String: Value]
    ) throws -> [String] {
        guard let value = arguments[key] else { return [] }
        guard let values = value.arrayValue else {
            throw DatabaseMCPInputError(message: "\(key) must be an array of strings.")
        }
        let strings = try values.map { value -> String in
            guard let string = value.stringValue else {
                throw DatabaseMCPInputError(message: "\(key) must contain only strings.")
            }
            return string.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard strings.count <= 32,
            strings.allSatisfy({ !$0.isEmpty && $0.count <= 512 })
        else {
            throw DatabaseMCPInputError(
                message: "\(key) must contain at most 32 non-empty strings of 512 characters.")
        }
        return strings
    }

    private static func target(
        in arguments: [String: Value],
        requiresObject: Bool
    ) throws -> DatabaseTargetIdentifier {
        let connectionID = try connectionID(in: arguments)
        let hasKind = arguments["object_kind"] != nil
        let hasPath = arguments["object_path"] != nil
        guard hasKind == hasPath else {
            throw DatabaseMCPInputError(
                message: "object_kind and object_path must be provided together.")
        }
        let path = try stringArray("object_path", in: arguments)
        if requiresObject, path.isEmpty {
            throw DatabaseMCPInputError(message: "object_path must contain at least one item.")
        }
        guard !path.isEmpty else {
            if hasPath {
                throw DatabaseMCPInputError(
                    message: "object_path must contain at least one item when provided.")
            }
            return DatabaseTargetIdentifier(connectionID: connectionID)
        }
        let rawKind = try requiredString("object_kind", in: arguments)
        guard let kind = DatabaseObjectKind(rawValue: rawKind) else {
            throw DatabaseMCPInputError(message: "object_kind is not supported.")
        }
        return DatabaseTargetIdentifier(
            connectionID: connectionID,
            object: DatabaseObjectIdentifier(kind: kind, path: path))
    }

    private static func keyMutationRequest(
        in arguments: [String: Value]
    ) throws -> DatabaseDestructiveRequest {
        let connectionID = try connectionID(in: arguments)
        let product: DatabaseProduct
        switch try requiredString("product", in: arguments) {
        case "redis": product = .redis
        case "valkey": product = .valkey
        default: throw DatabaseMCPInputError(message: "product must be redis or valkey.")
        }
        let logicalDatabase = try optionalString("logical_database", in: arguments) ?? "0"
        guard let logicalDatabaseNumber = Int(logicalDatabase), logicalDatabaseNumber >= 0,
            logicalDatabaseNumber.description == logicalDatabase
        else {
            throw DatabaseMCPInputError(
                message: "logical_database must be a non-negative integer.")
        }
        let key = try requiredString("key", in: arguments)
        guard key.utf8.count <= 4_096 else {
            throw DatabaseMCPInputError(message: "key must not exceed 4096 UTF-8 bytes.")
        }
        let value: String?
        if let provided = arguments["value"] {
            guard let string = provided.stringValue else {
                throw DatabaseMCPInputError(message: "value must be a string.")
            }
            guard string.utf8.count <= 65_536 else {
                throw DatabaseMCPInputError(message: "value must not exceed 65536 UTF-8 bytes.")
            }
            value = string
        } else {
            value = nil
        }
        let ttl = try optionalInt("ttl_ms", in: arguments).map(Int64.init)
        guard ttl.map({ $0 == -1 || $0 > 0 }) ?? true else {
            throw DatabaseMCPInputError(
                message: "ttl_ms must be positive or -1 for no expiry.")
        }
        let object = DatabaseObjectIdentifier(kind: .keyspace, path: [logicalDatabase])
        let keyValue = DatabaseValue.string(key)
        let record = DatabaseRecordIdentity(
            kind: .key,
            components: [DatabaseIdentityComponent(name: "key", value: keyValue)])
        let action = try requiredString("action", in: arguments)
        do {
            switch action {
            case "insert":
                guard let value else {
                    throw DatabaseMCPInputError(message: "insert requires value.")
                }
                return try DatabaseKeyspaceMutationRequests.insertString(
                    target: DatabaseTargetIdentifier(
                        connectionID: connectionID,
                        object: object),
                    product: product,
                    key: keyValue,
                    value: .string(value),
                    ttlMilliseconds: ttl)
            case "update":
                let target = DatabaseTargetIdentifier(
                    connectionID: connectionID,
                    object: object,
                    record: record)
                if let value {
                    return try DatabaseKeyspaceMutationRequests.updateString(
                        target: target,
                        product: product,
                        value: .string(value),
                        ttlMilliseconds: ttl == -1 ? nil : ttl,
                        preservesExistingTTL: ttl == nil)
                }
                guard let ttl else {
                    throw DatabaseMCPInputError(message: "update requires value or ttl_ms.")
                }
                return try DatabaseKeyspaceMutationRequests.updateTTL(
                    target: target,
                    product: product,
                    ttlMilliseconds: ttl == -1 ? nil : ttl)
            case "delete":
                guard value == nil, ttl == nil else {
                    throw DatabaseMCPInputError(
                        message: "delete does not accept value or ttl_ms.")
                }
                return try DatabaseKeyspaceMutationRequests.deleteKey(
                    target: DatabaseTargetIdentifier(
                        connectionID: connectionID,
                        object: object,
                        record: record),
                    product: product)
            default:
                throw DatabaseMCPInputError(message: "action must be insert, update or delete.")
            }
        } catch let error as DatabaseMCPInputError {
            throw error
        } catch {
            throw DatabaseMCPInputError(message: "The key mutation request is invalid.")
        }
    }

    private static func documentMutationRequest(
        in arguments: [String: Value]
    ) throws -> DatabaseDestructiveRequest {
        let connectionID = try connectionID(in: arguments)
        let product = try requiredString("product", in: arguments)
        guard product == "mongodb" || product == "elasticsearch" || product == "opensearch"
        else {
            throw DatabaseMCPInputError(
                message: "product must be mongodb, elasticsearch or opensearch.")
        }
        let document = try arguments["document"].map { value -> [DatabaseObjectField] in
            let maximumFields = product == "mongodb" ? 256 : 4_096
            guard let object = value.objectValue, object.count <= maximumFields else {
                throw DatabaseMCPInputError(message: "document must be a JSON object.")
            }
            var remaining = 4_096
            var remainingBytes = maximumDocumentBytes
            return try object.keys.sorted().map { name in
                try consumeDocumentBytes(name.utf8.count, remaining: &remainingBytes)
                return DatabaseObjectField(
                    name: name,
                    value: try databaseValue(
                        object[name]!,
                        depth: 0,
                        remaining: &remaining,
                        remainingBytes: &remainingBytes,
                        extendedJSON: product == "mongodb"))
            }
        }
        let documentID = try optionalString("document_id", in: arguments)
        do {
            if product == "mongodb" {
                return try mongoDBDocumentMutation(
                    arguments: arguments,
                    connectionID: connectionID,
                    documentID: documentID,
                    document: document)
            }
            return try searchDocumentMutation(
                arguments: arguments,
                connectionID: connectionID,
                product: product == "elasticsearch" ? .elasticsearch : .openSearch,
                documentID: documentID,
                document: document)
        } catch let error as DatabaseMCPInputError {
            throw error
        } catch {
            throw DatabaseMCPInputError(message: "The document mutation request is invalid.")
        }
    }

    private static func mongoDBDocumentMutation(
        arguments: [String: Value],
        connectionID: DatabaseConnectionID,
        documentID: String?,
        document: [DatabaseObjectField]?
    ) throws -> DatabaseDestructiveRequest {
        guard arguments["index"] == nil, arguments["sequence_number"] == nil,
            arguments["primary_term"] == nil,
            let database = try optionalString("database", in: arguments),
            let collection = try optionalString("collection", in: arguments),
            !database.isEmpty, !collection.isEmpty,
            database.utf8.count <= 255, collection.utf8.count <= 255
        else {
            throw DatabaseMCPInputError(
                message:
                    "MongoDB document mutations require database and collection without Elasticsearch fields."
            )
        }
        let target = DatabaseTargetIdentifier(
            connectionID: connectionID,
            object: DatabaseObjectIdentifier(kind: .collection, path: [database, collection]),
            record: try documentID.map {
                try documentIdentity(
                    $0,
                    kind: try optionalString("id_kind", in: arguments) ?? "object-id")
            })
        switch try requiredString("action", in: arguments) {
        case "insert":
            guard documentID == nil, let document else {
                throw DatabaseMCPInputError(
                    message: "insert requires document and does not accept document_id.")
            }
            return try DatabaseDocumentMutationRequests.mongoDBInsert(
                target: target,
                document: .object(document))
        case "update":
            guard documentID != nil, let document else {
                throw DatabaseMCPInputError(
                    message: "update requires document_id and document.")
            }
            return try DatabaseDocumentMutationRequests.mongoDBUpdate(
                target: target,
                values: document)
        case "delete":
            guard documentID != nil, document == nil else {
                throw DatabaseMCPInputError(
                    message: "delete requires document_id and does not accept document.")
            }
            return try DatabaseDocumentMutationRequests.mongoDBDelete(target: target)
        default:
            throw DatabaseMCPInputError(message: "action must be insert, update or delete.")
        }
    }

    private static func searchDocumentMutation(
        arguments: [String: Value],
        connectionID: DatabaseConnectionID,
        product: DatabaseProduct,
        documentID: String?,
        document: [DatabaseObjectField]?
    ) throws -> DatabaseDestructiveRequest {
        guard arguments["database"] == nil, arguments["collection"] == nil,
            arguments["id_kind"] == nil,
            let index = try optionalString("index", in: arguments),
            !index.isEmpty, index.utf8.count <= 255,
            let documentID, !documentID.isEmpty, documentID.utf8.count <= 512
        else {
            throw DatabaseMCPInputError(
                message:
                    "Search document mutations require index and document_id without MongoDB fields."
            )
        }
        let action = try requiredString("action", in: arguments)
        let requiresConcurrency = action != "insert"
        let sequenceNumber = try optionalInt("sequence_number", in: arguments)
        let primaryTerm = try optionalInt("primary_term", in: arguments)
        let concurrencyTokens: [DatabaseIdentityComponent]
        if requiresConcurrency {
            guard let sequenceNumber, let primaryTerm,
                sequenceNumber >= 0, primaryTerm >= 0
            else {
                throw DatabaseMCPInputError(
                    message:
                        "Search update and delete require sequence_number and primary_term."
                )
            }
            concurrencyTokens = [
                DatabaseIdentityComponent(
                    name: "_seq_no",
                    value: .signedInteger(Int64(sequenceNumber))),
                DatabaseIdentityComponent(
                    name: "_primary_term",
                    value: .signedInteger(Int64(primaryTerm))),
            ]
        } else {
            guard sequenceNumber == nil, primaryTerm == nil else {
                throw DatabaseMCPInputError(
                    message: "Search insert does not accept concurrency fields.")
            }
            concurrencyTokens = []
        }
        let target = DatabaseTargetIdentifier(
            connectionID: connectionID,
            object: DatabaseObjectIdentifier(kind: .index, path: [index]),
            record: DatabaseRecordIdentity(
                kind: .searchDocument,
                components: [
                    DatabaseIdentityComponent(name: "_index", value: .string(index)),
                    DatabaseIdentityComponent(name: "_id", value: .string(documentID)),
                ],
                concurrencyTokens: concurrencyTokens))
        switch action {
        case "insert":
            guard let document else {
                throw DatabaseMCPInputError(message: "insert requires document.")
            }
            return
                if product == .elasticsearch
            {
                try DatabaseDocumentMutationRequests.elasticsearchCreate(
                    target: target,
                    document: .object(document))
            } else {
                try DatabaseDocumentMutationRequests.openSearchCreate(
                    target: target,
                    document: .object(document))
            }
        case "update":
            guard let document else {
                throw DatabaseMCPInputError(message: "update requires document.")
            }
            return
                if product == .elasticsearch
            {
                try DatabaseDocumentMutationRequests.elasticsearchReplace(
                    target: target,
                    document: .object(document))
            } else {
                try DatabaseDocumentMutationRequests.openSearchReplace(
                    target: target,
                    document: .object(document))
            }
        case "delete":
            guard document == nil else {
                throw DatabaseMCPInputError(message: "delete does not accept document.")
            }
            return
                if product == .elasticsearch
            {
                try DatabaseDocumentMutationRequests.elasticsearchDelete(target: target)
            } else {
                try DatabaseDocumentMutationRequests.openSearchDelete(target: target)
            }
        default:
            throw DatabaseMCPInputError(message: "action must be insert, update or delete.")
        }
    }

    private static func documentIdentity(
        _ value: String,
        kind: String
    ) throws -> DatabaseRecordIdentity {
        let parsed: DatabaseValue
        switch kind {
        case "object-id":
            guard value.count == 24, value.allSatisfy(\.isHexDigit) else {
                throw DatabaseMCPInputError(
                    message: "object-id document identifiers require 24 hex characters.")
            }
            parsed = .productSpecific(
                DatabaseProductValue(
                    product: .mongoDB,
                    typeName: "objectId",
                    textRepresentation: value.lowercased()))
        case "string":
            parsed = .string(value)
        case "integer":
            guard let integer = Int64(value) else {
                throw DatabaseMCPInputError(
                    message: "integer document identifiers require an Int64 value.")
            }
            parsed = .signedInteger(integer)
        case "uuid":
            guard let uuid = UUID(uuidString: value) else {
                throw DatabaseMCPInputError(
                    message: "uuid document identifiers require a UUID value.")
            }
            parsed = .uuid(uuid)
        default:
            throw DatabaseMCPInputError(
                message: "id_kind must be object-id, string, integer or uuid.")
        }
        return DatabaseRecordIdentity(
            kind: .documentID,
            components: [DatabaseIdentityComponent(name: "_id", value: parsed)])
    }

    private static func databaseValue(
        _ value: Value,
        depth: Int,
        remaining: inout Int,
        remainingBytes: inout Int,
        extendedJSON: Bool
    ) throws -> DatabaseValue {
        guard depth <= 16, remaining > 0 else {
            throw DatabaseMCPInputError(message: "document exceeds the bounded value limit.")
        }
        remaining -= 1
        switch value {
        case .null:
            return .null
        case .bool(let value):
            return .boolean(value)
        case .int(let value):
            return .signedInteger(Int64(value))
        case .double(let value):
            guard value.isFinite else {
                throw DatabaseMCPInputError(message: "document contains a non-finite number.")
            }
            return .floatingPoint(value)
        case .string(let value):
            try consumeDocumentBytes(value.utf8.count, remaining: &remainingBytes)
            return .string(value)
        case .data(_, let value):
            try consumeDocumentBytes(value.count, remaining: &remainingBytes)
            return .binary(.complete(data: value, mediaType: nil, digest: nil))
        case .array(let values):
            return .array(
                try values.map {
                    try databaseValue(
                        $0,
                        depth: depth + 1,
                        remaining: &remaining,
                        remainingBytes: &remainingBytes,
                        extendedJSON: extendedJSON)
                })
        case .object(let fields):
            if extendedJSON, fields.count == 1 {
                if let raw = fields["$oid"]?.stringValue {
                    return .productSpecific(
                        DatabaseProductValue(
                            product: .mongoDB,
                            typeName: "objectId",
                            textRepresentation: raw))
                }
                if let raw = fields["$date"]?.stringValue {
                    return .timestamp(DatabaseTimestampValue(text: raw))
                }
                if let raw = fields["$uuid"]?.stringValue, let uuid = UUID(uuidString: raw) {
                    return .uuid(uuid)
                }
            }
            return .object(
                try fields.keys.sorted().map { name in
                    try consumeDocumentBytes(name.utf8.count, remaining: &remainingBytes)
                    return DatabaseObjectField(
                        name: name,
                        value: try databaseValue(
                            fields[name]!,
                            depth: depth + 1,
                            remaining: &remaining,
                            remainingBytes: &remainingBytes,
                            extendedJSON: extendedJSON))
                })
        }
    }

    private static func consumeDocumentBytes(
        _ count: Int,
        remaining: inout Int
    ) throws {
        guard count <= remaining else {
            throw DatabaseMCPInputError(message: "document exceeds the 1 MB value limit.")
        }
        remaining -= count
    }

    private static func pageRequest(
        in arguments: [String: Value]
    ) throws -> DatabasePageRequest {
        let size = try optionalInt("page_size", in: arguments) ?? 100
        guard (1...maximumPageSize).contains(size) else {
            throw DatabaseMCPInputError(
                message: "page_size must be between 1 and \(maximumPageSize).")
        }
        let continuation = try optionalString("continuation", in: arguments)
        if let continuation, continuation.count > maximumContinuationCharacters {
            throw DatabaseMCPInputError(
                message:
                    "continuation must not exceed \(maximumContinuationCharacters) characters.")
        }
        return DatabasePageRequest(
            pageSize: try DatabasePageSize(size),
            continuation: continuation.map(DatabaseContinuationToken.init(rawValue:)))
    }

    private static func queryLanguage(
        in arguments: [String: Value]
    ) throws -> DatabaseQueryLanguage {
        let rawValue = try requiredString("language", in: arguments)
        guard let language = DatabaseQueryLanguage(rawValue: rawValue) else {
            throw DatabaseMCPInputError(message: "language is not supported.")
        }
        return language
    }

    private static func operationID(
        in arguments: [String: Value]
    ) throws -> DatabaseOperationID {
        let rawValue = try requiredString("operation_id", in: arguments)
        guard let value = UUID(uuidString: rawValue) else {
            throw DatabaseMCPInputError(message: "operation_id must be a UUID.")
        }
        return DatabaseOperationID(rawValue: value)
    }

    private static func optionalConnectionID(
        in arguments: [String: Value]
    ) throws -> DatabaseConnectionID? {
        guard arguments["connection_id"] != nil else { return nil }
        return try connectionID(in: arguments)
    }

    private static func operationStates(
        in arguments: [String: Value]
    ) throws -> Set<DatabaseOperationState> {
        let values = try stringArray("states", in: arguments)
        guard values.count <= DatabaseOperationState.allCases.count else {
            throw DatabaseMCPInputError(message: "states contains too many values.")
        }
        return try Set(
            values.map { value in
                guard let state = DatabaseOperationState(rawValue: value) else {
                    throw DatabaseMCPInputError(message: "states contains an unsupported value.")
                }
                return state
            })
    }

    private static func operationKinds(
        in arguments: [String: Value]
    ) throws -> Set<DatabaseOperationKind> {
        let values = try stringArray("kinds", in: arguments)
        guard values.allSatisfy({ $0.count <= 256 }) else {
            throw DatabaseMCPInputError(
                message: "kinds must not contain values longer than 256 characters.")
        }
        return Set(values.map(DatabaseOperationKind.init(rawValue:)))
    }

    private static func optionalDate(
        _ key: String,
        in arguments: [String: Value]
    ) throws -> Date? {
        guard let rawValue = try optionalString(key, in: arguments) else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let value = formatter.date(from: rawValue) {
            return value
        }
        formatter.formatOptions = [.withInternetDateTime]
        guard let value = formatter.date(from: rawValue) else {
            throw DatabaseMCPInputError(message: "\(key) must be an ISO 8601 timestamp.")
        }
        return value
    }

    private static func connectionID(
        in arguments: [String: Value]
    ) throws -> DatabaseConnectionID {
        let rawValue = try requiredString("connection_id", in: arguments)
        guard let value = UUID(uuidString: rawValue) else {
            throw DatabaseMCPInputError(message: "connection_id must be a UUID.")
        }
        return DatabaseConnectionID(rawValue: value)
    }

    private static func rejectUnknown(
        _ arguments: [String: Value],
        allowed: Set<String>
    ) throws {
        let unknown = arguments.keys.filter { !allowed.contains($0) }.sorted()
        guard unknown.isEmpty else {
            throw DatabaseMCPInputError(
                message: "Unknown argument: \(bounded(unknown[0])).")
        }
    }

    private static func optional(_ value: String?) -> Value {
        value.map { .string(bounded($0)) } ?? .null
    }

    private static func optionalInt(_ value: Int?) -> Value {
        value.map(Value.int) ?? .null
    }

    private static func unsigned(_ value: UInt64) -> Value {
        Int(exactly: value).map(Value.int) ?? .string(String(value))
    }

    private static func uuid(_ value: UUID) -> Value {
        .string(value.uuidString.lowercased())
    }

    private static func date(_ value: Date) -> Value {
        .string(value.ISO8601Format(.init(includingFractionalSeconds: true)))
    }

    private static func optionalDate(_ value: Date?) -> Value {
        value.map(date) ?? .null
    }

    private static func bounded(_ value: String) -> String {
        String(value.prefix(maximumTextCharacters))
    }
}

private struct DatabaseMCPInputError: Error {
    let message: String
}
