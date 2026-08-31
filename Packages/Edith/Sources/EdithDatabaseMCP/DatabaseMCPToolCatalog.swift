import EdithDatabase
import MCP

public enum DatabaseMCPToolName: String, CaseIterable, Sendable {
    case connections = "database_connections"
    case capabilities = "database_capabilities"
    case browse = "database_browse"
    case query = "database_query"
    case operations = "database_operations"
    case cancelOperation = "database_cancel_operation"
    case testConnection = "database_test_connection"
    case session = "database_session"
    case keyMutation = "database_key_mutation"
    case documentMutation = "database_document_mutation"
}

public enum DatabaseMCPToolCatalog {
    public static let tools: [Tool] = [
        connections, capabilities, browse, query, operations, cancelOperation,
        testConnection, session, keyMutation, documentMutation,
    ]

    public static let connections = Tool(
        name: DatabaseMCPToolName.connections.rawValue,
        title: "Database connections",
        description: "List saved database connections or get one connection by identifier.",
        inputSchema: .object([
            "type": "object",
            "properties": .object([
                "action": .object([
                    "type": "string",
                    "enum": .array(["list", "get"]),
                    "description": "Choose list or get.",
                ]),
                "connection_id": .object([
                    "type": "string",
                    "format": "uuid",
                    "description": "Required for get.",
                ]),
                "search": .object([
                    "type": "string",
                    "maxLength": 256,
                    "description": "Optional bounded search for list.",
                ]),
            ]),
            "required": .array(["action"]),
            "additionalProperties": false,
        ]),
        annotations: .init(
            title: "Inspect database connections",
            readOnlyHint: true,
            destructiveHint: false,
            idempotentHint: true,
            openWorldHint: false),
        outputSchema: responseSchema(
            data: .object([
                "type": "object",
                "properties": .object([
                    "action": .object([
                        "type": "string",
                        "enum": .array(["list", "get"]),
                    ]),
                    "connections": .object([
                        "type": "array",
                        "maxItems": 100,
                        "items": connectionProjectionSchema,
                    ]),
                    "connection": .object([
                        "anyOf": .array([
                            connectionProjectionSchema,
                            .object(["type": "null"]),
                        ])
                    ]),
                    "returned_count": .object([
                        "type": "integer",
                        "minimum": 0,
                        "maximum": 100,
                    ]),
                ]),
                "required": .array(["action"]),
                "additionalProperties": false,
            ])))

    public static let capabilities = Tool(
        name: DatabaseMCPToolName.capabilities.rawValue,
        title: "Database capabilities",
        description: "Inspect discovered capabilities for one saved database connection.",
        inputSchema: .object([
            "type": "object",
            "properties": .object([
                "connection_id": .object([
                    "type": "string",
                    "format": "uuid",
                    "description": "Saved database connection identifier.",
                ]),
                "refresh": .object([
                    "type": "boolean",
                    "description": "Discover fresh capabilities instead of using a valid cache.",
                ]),
            ]),
            "required": .array(["connection_id"]),
            "additionalProperties": false,
        ]),
        annotations: .init(
            title: "Inspect database capabilities",
            readOnlyHint: true,
            destructiveHint: false,
            idempotentHint: true,
            openWorldHint: false),
        outputSchema: responseSchema(
            data: .object([
                "type": "object",
                "properties": .object([
                    "connection_id": uuidSchema,
                    "source": .object([
                        "type": "string",
                        "enum": .array(["cached", "discovered"]),
                    ]),
                    "report": .object([
                        "type": "object",
                        "properties": .object([
                            "product": .object(["type": "object"]),
                            "capabilities": .object([
                                "type": "array",
                                "maxItems": 256,
                                "items": .object(["type": "object"]),
                            ]),
                            "permissions": .object([
                                "type": "array",
                                "maxItems": 64,
                                "items": .object(["type": "object"]),
                            ]),
                            "safety_limitations": .object([
                                "type": "array",
                                "maxItems": 64,
                                "items": .object(["type": "string"]),
                            ]),
                            "discovered_at": .object(["type": "string"]),
                            "expires_at": .object([
                                "type": .array(["string", "null"])
                            ]),
                        ]),
                        "required": .array([
                            "product", "capabilities", "permissions",
                            "safety_limitations", "discovered_at", "expires_at",
                        ]),
                    ]),
                ]),
                "required": .array(["connection_id", "source", "report"]),
                "additionalProperties": false,
            ])))

    public static let browse = Tool(
        name: DatabaseMCPToolName.browse.rawValue,
        title: "Browse database records",
        description: "Read one bounded page from an explicit object on a saved connection.",
        inputSchema: pageInputSchema(command: false),
        annotations: .init(
            title: "Browse database records",
            readOnlyHint: true,
            destructiveHint: false,
            idempotentHint: true,
            openWorldHint: false),
        outputSchema: pageResponseSchema)

    public static let query = Tool(
        name: DatabaseMCPToolName.query.rawValue,
        title: "Run a bounded database read query",
        description: "Run one bounded read query on an explicit saved connection.",
        inputSchema: pageInputSchema(command: true),
        annotations: .init(
            title: "Run a bounded database read query",
            readOnlyHint: true,
            destructiveHint: false,
            idempotentHint: true,
            openWorldHint: false),
        outputSchema: pageResponseSchema)

    public static let keyMutation = Tool(
        name: DatabaseMCPToolName.keyMutation.rawValue,
        title: "Preview or apply one Redis-compatible key mutation",
        description:
            "Create, update, expire, persist, or delete one explicit Redis or Valkey string key through preview-bound confirmation.",
        inputSchema: .object([
            "type": "object",
            "properties": .object([
                "mode": .object([
                    "type": "string",
                    "enum": .array(["preview", "apply"]),
                ]),
                "connection_id": uuidSchema,
                "product": .object([
                    "type": "string",
                    "enum": .array(["redis", "valkey"]),
                ]),
                "action": .object([
                    "type": "string",
                    "enum": .array(["insert", "update", "delete"]),
                ]),
                "logical_database": .object([
                    "type": "string",
                    "pattern": "^[0-9]+$",
                    "maxLength": 10,
                ]),
                "key": .object([
                    "type": "string",
                    "minLength": 1,
                    "maxLength": 4096,
                ]),
                "value": .object([
                    "type": "string",
                    "maxLength": 65536,
                ]),
                "ttl_ms": .object([
                    "type": "integer",
                    "description": "Positive TTL in milliseconds, or -1 for no expiry.",
                ]),
                "confirmation_token": .object(["type": "string"]),
                "confirmation_text": .object(["type": "string"]),
                "timeout_ms": .object([
                    "type": "integer",
                    "minimum": 1,
                    "maximum": 86400000,
                ]),
            ]),
            "required": .array(["mode", "connection_id", "product", "action", "key"]),
            "additionalProperties": false,
        ]),
        annotations: .init(
            title: "Mutate one Redis-compatible key",
            readOnlyHint: false,
            destructiveHint: true,
            idempotentHint: false,
            openWorldHint: false),
        outputSchema: responseSchema(data: .object(["type": "object"])))

    public static let documentMutation = Tool(
        name: DatabaseMCPToolName.documentMutation.rawValue,
        title: "Preview or apply one document mutation",
        description:
            "Insert, update, or delete one explicit MongoDB or Elasticsearch document through preview-bound confirmation.",
        inputSchema: .object([
            "type": "object",
            "properties": .object([
                "mode": .object([
                    "type": "string",
                    "enum": .array(["preview", "apply"]),
                ]),
                "connection_id": uuidSchema,
                "product": .object([
                    "type": "string",
                    "enum": .array(["mongodb", "elasticsearch"]),
                ]),
                "action": .object([
                    "type": "string",
                    "enum": .array(["insert", "update", "delete"]),
                ]),
                "database": .object(["type": "string", "maxLength": 255]),
                "collection": .object(["type": "string", "maxLength": 255]),
                "index": .object(["type": "string", "maxLength": 255]),
                "document": .object([
                    "type": "object",
                    "maxProperties": 256,
                    "additionalProperties": true,
                ]),
                "document_id": .object(["type": "string", "maxLength": 1024]),
                "id_kind": .object([
                    "type": "string",
                    "enum": .array(["object-id", "string", "integer", "uuid"]),
                ]),
                "sequence_number": .object(["type": "integer", "minimum": 0]),
                "primary_term": .object(["type": "integer", "minimum": 0]),
                "confirmation_token": .object(["type": "string"]),
                "confirmation_text": .object(["type": "string"]),
                "timeout_ms": .object([
                    "type": "integer",
                    "minimum": 1,
                    "maximum": 86400000,
                ]),
            ]),
            "required": .array(["mode", "connection_id", "product", "action"]),
            "additionalProperties": false,
        ]),
        annotations: .init(
            title: "Mutate one database document",
            readOnlyHint: false,
            destructiveHint: true,
            idempotentHint: false,
            openWorldHint: false),
        outputSchema: responseSchema(data: .object(["type": "object"])))

    public static let operations = Tool(
        name: DatabaseMCPToolName.operations.rawValue,
        title: "Database operations",
        description: "List tracked database operations or get one operation by identifier.",
        inputSchema: .object([
            "type": "object",
            "properties": .object([
                "action": .object([
                    "type": "string",
                    "enum": .array(["list", "get"]),
                ]),
                "operation_id": uuidSchema,
                "connection_id": uuidSchema,
                "states": .object([
                    "type": "array",
                    "maxItems": 7,
                    "items": .object([
                        "type": "string",
                        "enum": .array([
                            "queued", "running", "cancelling", "succeeded", "failed",
                            "cancelled", "partiallySucceeded",
                        ]),
                    ]),
                ]),
                "kinds": .object([
                    "type": "array",
                    "maxItems": 32,
                    "items": .object([
                        "type": "string",
                        "minLength": 1,
                        "maxLength": 256,
                    ]),
                ]),
                "before": .object([
                    "type": "string",
                    "format": "date-time",
                ]),
                "limit": .object([
                    "type": "integer",
                    "minimum": 1,
                    "maximum": 1000,
                ]),
            ]),
            "required": .array(["action"]),
            "additionalProperties": false,
        ]),
        annotations: .init(
            title: "Inspect database operations",
            readOnlyHint: true,
            destructiveHint: false,
            idempotentHint: true,
            openWorldHint: false),
        outputSchema: responseSchema(
            data: .object([
                "type": "object",
                "properties": .object([
                    "action": .object([
                        "type": "string",
                        "enum": .array(["list", "get"]),
                    ]),
                    "operations": .object([
                        "type": "array",
                        "maxItems": 1000,
                        "items": .object(["type": "object"]),
                    ]),
                    "operation": .object([
                        "anyOf": .array([
                            .object(["type": "object"]),
                            .object(["type": "null"]),
                        ])
                    ]),
                ]),
                "required": .array(["action"]),
                "additionalProperties": false,
            ])))

    public static let cancelOperation = Tool(
        name: DatabaseMCPToolName.cancelOperation.rawValue,
        title: "Cancel database operation",
        description: "Request cancellation of one tracked database operation.",
        inputSchema: .object([
            "type": "object",
            "properties": .object([
                "operation_id": uuidSchema
            ]),
            "required": .array(["operation_id"]),
            "additionalProperties": false,
        ]),
        annotations: .init(
            title: "Cancel database operation",
            readOnlyHint: false,
            destructiveHint: false,
            idempotentHint: true,
            openWorldHint: false),
        outputSchema: responseSchema(
            data: .object([
                "type": "object",
                "properties": .object([
                    "operation_id": uuidSchema,
                    "disposition": .object([
                        "type": "string",
                        "enum": .array(["accepted", "alreadyFinished", "notActive", "notFound"]),
                    ]),
                    "cancellation_support": .object(["type": "string"]),
                    "operation": .object([
                        "anyOf": .array([
                            .object(["type": "object"]),
                            .object(["type": "null"]),
                        ])
                    ]),
                ]),
                "required": .array([
                    "operation_id", "disposition", "cancellation_support", "operation",
                ]),
                "additionalProperties": false,
            ])))

    public static let testConnection = Tool(
        name: DatabaseMCPToolName.testConnection.rawValue,
        title: "Test database connection",
        description: "Test one saved connection without opening a persistent session.",
        inputSchema: connectionOperationInputSchema(action: false),
        annotations: .init(
            title: "Test database connection",
            readOnlyHint: true,
            destructiveHint: false,
            idempotentHint: true,
            openWorldHint: false),
        outputSchema: responseSchema(
            data: .object([
                "type": "object",
                "properties": .object([
                    "connection_id": uuidSchema,
                    "display_name": .object(["type": "string"]),
                    "product": .object(["type": "string"]),
                    "version": .object(["type": .array(["string", "null"])]),
                    "latency_ms": .object(["type": "integer", "minimum": 0]),
                    "tested_at": .object(["type": "string"]),
                    "operation_id": uuidSchema,
                ]),
                "required": .array([
                    "connection_id", "display_name", "product", "version", "latency_ms",
                    "tested_at", "operation_id",
                ]),
                "additionalProperties": false,
            ])))

    public static let session = Tool(
        name: DatabaseMCPToolName.session.rawValue,
        title: "Database session",
        description: "Explicitly connect or disconnect one saved database session.",
        inputSchema: connectionOperationInputSchema(action: true),
        annotations: .init(
            title: "Manage database session",
            readOnlyHint: false,
            destructiveHint: false,
            idempotentHint: true,
            openWorldHint: false),
        outputSchema: responseSchema(
            data: .object([
                "type": "object",
                "properties": .object([
                    "action": .object([
                        "type": "string",
                        "enum": .array(["connect", "disconnect"]),
                    ]),
                    "connection_id": uuidSchema,
                    "display_name": .object(["type": "string"]),
                    "product": .object(["type": .array(["string", "null"])]),
                    "version": .object(["type": .array(["string", "null"])]),
                    "disconnected": .object(["type": .array(["boolean", "null"])]),
                    "completed_at": .object(["type": "string"]),
                    "operation_id": uuidSchema,
                ]),
                "required": .array([
                    "action", "connection_id", "display_name", "product", "version",
                    "disconnected", "completed_at", "operation_id",
                ]),
                "additionalProperties": false,
            ])))

    private static let uuidSchema = Value.object([
        "type": "string",
        "format": "uuid",
    ])

    private static let connectionProjectionSchema = Value.object([
        "type": "object",
        "properties": .object([
            "id": uuidSchema,
            "display_name": .object(["type": "string"]),
            "product": .object(["type": "string"]),
            "family": .object(["type": "string"]),
            "environment": .object(["type": "object"]),
            "namespace_defaults": .object(["type": "object"]),
            "read_only_policy": .object(["type": "string"]),
            "production_policy": .object(["type": "string"]),
            "group": .object(["type": .array(["string", "null"])]),
            "tags": .object([
                "type": "array",
                "maxItems": 64,
                "items": .object(["type": "string"]),
            ]),
            "color": .object(["type": .array(["string", "null"])]),
            "is_favorite": .object(["type": "boolean"]),
            "created_at": .object(["type": "string"]),
            "updated_at": .object(["type": "string"]),
            "last_tested_at": .object(["type": .array(["string", "null"])]),
            "last_used_at": .object(["type": .array(["string", "null"])]),
        ]),
        "required": .array([
            "id", "display_name", "product", "family", "environment",
            "namespace_defaults", "read_only_policy", "production_policy", "group", "tags",
            "color", "is_favorite", "created_at", "updated_at", "last_tested_at",
            "last_used_at",
        ]),
        "additionalProperties": false,
    ])

    private static let pageResponseSchema = responseSchema(
        data: .object([
            "type": "object",
            "properties": .object([
                "connection_id": uuidSchema,
                "page": .object([
                    "type": "object",
                    "properties": .object([
                        "records": .object([
                            "type": "array",
                            "maxItems": 500,
                            "items": .object(["type": "object"]),
                        ]),
                        "fields": .object([
                            "type": "array",
                            "maxItems": 256,
                            "items": .object(["type": "object"]),
                        ]),
                        "next_continuation": .object([
                            "type": .array(["string", "null"])
                        ]),
                        "metadata": .object(["type": "object"]),
                    ]),
                    "required": .array([
                        "records", "fields", "next_continuation", "metadata",
                    ]),
                    "additionalProperties": false,
                ]),
            ]),
            "required": .array(["connection_id", "page"]),
            "additionalProperties": false,
        ]))

    private static func pageInputSchema(command: Bool) -> Value {
        var properties: [String: Value] = [
            "connection_id": uuidSchema,
            "object_kind": .object([
                "type": "string",
                "enum": .array(DatabaseObjectKind.allCases.map { .string($0.rawValue) }),
            ]),
            "object_path": .object([
                "type": "array",
                "minItems": command ? 0 : 1,
                "maxItems": 32,
                "items": .object([
                    "type": "string",
                    "minLength": 1,
                    "maxLength": 512,
                ]),
            ]),
            "page_size": .object([
                "type": "integer",
                "minimum": 1,
                "maximum": 500,
            ]),
            "continuation": .object([
                "type": "string",
                "maxLength": 32768,
            ]),
            "timeout_ms": .object([
                "type": "integer",
                "minimum": 1,
                "maximum": 86400000,
            ]),
        ]
        var required = ["connection_id"]
        if command {
            properties["language"] = .object([
                "type": "string",
                "enum": .array([
                    "sql", "redisCommand", "mongoQuery", "searchQueryDSL", "clickHouseSQL",
                ]),
            ])
            properties["command"] = .object([
                "type": "string",
                "minLength": 1,
                "maxLength": 262144,
            ])
            required.append(contentsOf: ["language", "command"])
        } else {
            required.append(contentsOf: ["object_kind", "object_path"])
        }
        return .object([
            "type": "object",
            "properties": .object(properties),
            "required": .array(required.map(Value.string)),
            "additionalProperties": false,
        ])
    }

    private static func connectionOperationInputSchema(action: Bool) -> Value {
        var properties: [String: Value] = [
            "connection_id": uuidSchema,
            "timeout_ms": .object([
                "type": "integer",
                "minimum": 1,
                "maximum": 86400000,
            ]),
        ]
        var required = ["connection_id"]
        if action {
            properties["action"] = .object([
                "type": "string",
                "enum": .array(["connect", "disconnect"]),
            ])
            required.insert("action", at: 0)
        }
        return .object([
            "type": "object",
            "properties": .object(properties),
            "required": .array(required.map(Value.string)),
            "additionalProperties": false,
        ])
    }

    private static func responseSchema(data: Value) -> Value {
        .object([
            "type": "object",
            "properties": .object([
                "status": .object([
                    "type": "string",
                    "enum": .array(["succeeded", "partiallySucceeded", "failed"]),
                ]),
                "data": data,
                "metadata": .object(["type": "object"]),
                "error": .object(["type": "object"]),
            ]),
            "required": .array(["status"]),
            "additionalProperties": false,
        ])
    }
}
