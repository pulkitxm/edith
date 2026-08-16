import Foundation

public enum ConfigSchema {
    public static let id = "https://edith.pulkit.page/schema/config.json"

    public static func document(
        settings: [SettingDefinition] = ConfigCatalog.settings
    ) -> JSONValue {
        var properties: [String: JSONValue] = [:]
        for definition in settings where !definition.readOnly {
            properties[definition.key] = property(definition)
        }
        return .object([
            "$schema": .string("https://json-schema.org/draft/2020-12/schema"),
            "$id": .string(id),
            "title": .string("Edith configuration"),
            "description": .string(
                "Every setting the Edith UI exposes, as accepted by `ed config import`. "
                    + "Keys map one to one onto the preferences the app reads at runtime."),
            "type": .string("object"),
            "additionalProperties": .bool(false),
            "properties": .object(properties),
        ])
    }

    static func property(_ definition: SettingDefinition) -> JSONValue {
        var fields: [String: JSONValue] = [
            "description": .string(definition.summary),
            "x-group": .string(definition.group),
            "x-scope": .string(definition.scope.rawValue),
        ]
        switch definition.type {
        case .bool:
            fields["type"] = .string("boolean")
        case .int:
            fields["type"] = .string("integer")
        case .number:
            fields["type"] = .string("number")
        case .string:
            fields["type"] = .string("string")
        case .csv:
            fields["type"] = .string("string")
            fields["x-format"] = .string("comma-separated")
        case .stringList:
            fields["type"] = .string("array")
            fields["items"] = .object(["type": .string("string")])
        case .map:
            fields["type"] = .string("object")
        }
        if !definition.allowed.isEmpty {
            fields["enum"] = .strings(definition.allowed)
        }
        if definition.fallback != .null {
            fields["default"] = definition.fallback
        }
        return .object(fields)
    }
}
