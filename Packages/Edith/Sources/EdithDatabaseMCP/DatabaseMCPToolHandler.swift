import EdithDatabase
import Foundation
import MCP

public struct DatabaseMCPToolHandler: Sendable {
    private static let maximumSearchCharacters = 256
    private static let maximumTextCharacters = 2_048
    private static let maximumConnections = 100
    private static let maximumCapabilities = 256
    private static let maximumCollectionItems = 64

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
                category: "invalidRequest", message: "The broker rejected the database request.")
        case .timedOut:
            failure(category: "timeout", message: "The local database broker request timed out.")
        case .unavailable:
            failure(category: "network", message: "The local database broker is unavailable.")
        case .unsafePeer:
            failure(
                category: "authenticationFailed",
                message: "The local database broker failed peer authentication.")
        case .outcomeUnknown:
            failure(
                category: "network",
                message: "The local database broker could not confirm the request outcome.")
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
            "started_at": optionalDate(value.startedAt),
            "finished_at": optionalDate(value.finishedAt),
            "deadline": optionalDate(value.deadline),
            "cancellation_support": .string(value.cancellationSupport.rawValue),
            "retry_classification": .string(value.retryClassification.rawValue),
            "page_count": unsigned(value.pageCount),
            "record_count": unsigned(value.recordCount),
            "byte_count": unsigned(value.byteCount),
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
