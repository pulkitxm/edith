import MCP

public enum DatabaseMCPToolName: String, CaseIterable, Sendable {
    case connections = "database_connections"
    case capabilities = "database_capabilities"
}

public enum DatabaseMCPToolCatalog {
    public static let tools: [Tool] = [connections, capabilities]

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
