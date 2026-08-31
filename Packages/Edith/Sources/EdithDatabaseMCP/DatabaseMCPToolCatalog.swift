import MCP

public enum DatabaseMCPToolName: String, CaseIterable, Sendable {
    case connections = "database_connections"
    case capabilities = "database_capabilities"
    case browse = "database_browse"
    case query = "database_query"
}

public enum DatabaseMCPToolCatalog {
    public static let tools: [Tool] = [connections, capabilities, browse, query]

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
                "enum": .array([
                    "table", "view", "materializedView", "key", "collection", "alias",
                    "dataStream", "dictionary", "other",
                ]),
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
