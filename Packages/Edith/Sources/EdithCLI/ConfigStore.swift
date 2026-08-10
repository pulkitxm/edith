import EdithKit
import Foundation

public enum ConfigValueParser {
    public static func parse(_ raw: String, as type: SettingDefinition.ValueType, allowed: [String])
        throws -> JSONValue
    {
        switch type {
        case .bool:
            return .bool(try boolean(raw))
        case .int:
            guard let value = Int(raw.trimmingCharacters(in: .whitespaces)) else {
                throw CLIFailure("\(raw) is not a whole number")
            }
            return .int(value)
        case .number:
            guard let value = Double(raw.trimmingCharacters(in: .whitespaces)) else {
                throw CLIFailure("\(raw) is not a number")
            }
            return .double(value)
        case .string, .csv:
            guard allowed.isEmpty || allowed.contains(raw) else {
                throw CLIFailure(
                    "\(raw) is not a valid value",
                    hint: "allowed: " + allowed.joined(separator: ", "))
            }
            return .string(raw)
        case .stringList:
            let items =
                raw.isEmpty
                ? []
                : raw.split(separator: ",").map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
            return .strings(items)
        case .map:
            throw CLIFailure(
                "\(type.rawValue) settings cannot be set from the command line",
                hint: "edit it in the app instead")
        }
    }

    public static func boolean(_ raw: String) throws -> Bool {
        switch raw.lowercased() {
        case "1", "true", "yes", "on", "enabled": return true
        case "0", "false", "no", "off", "disabled": return false
        default: throw CLIFailure("\(raw) is not a boolean, use true or false")
        }
    }
}

public struct ConfigStore {
    private let shared: UserDefaults
    private let standard: UserDefaults

    public init(
        shared: UserDefaults = CLIEnvironment.sharedDefaults,
        standard: UserDefaults = CLIEnvironment.standardDefaults
    ) {
        self.shared = shared
        self.standard = standard
    }

    public func defaults(for definition: SettingDefinition) -> UserDefaults {
        definition.scope == .shared ? shared : standard
    }

    public func value(for definition: SettingDefinition) -> JSONValue {
        let store = defaults(for: definition)
        guard let object = store.object(forKey: definition.key) else { return definition.fallback }
        switch definition.type {
        case .bool:
            return .bool(store.bool(forKey: definition.key))
        case .int:
            return .int(store.integer(forKey: definition.key))
        case .number:
            return .double(store.double(forKey: definition.key))
        case .string, .csv:
            return .optional(store.string(forKey: definition.key))
        case .stringList:
            return .strings(store.stringArray(forKey: definition.key) ?? [])
        case .map:
            return Self.encode(object)
        }
    }

    public func isSet(_ definition: SettingDefinition) -> Bool {
        guard let stored = defaults(for: definition).object(forKey: definition.key) else {
            return false
        }
        let registered = UserDefaults.standard.volatileDomain(
            forName: UserDefaults.registrationDomain)
        guard let registeredValue = registered[definition.key] else { return true }
        return !(stored as AnyObject).isEqual(registeredValue)
    }

    public func set(_ value: JSONValue, for definition: SettingDefinition) throws {
        guard !definition.readOnly else {
            throw CLIFailure("\(definition.key) is read only")
        }
        let store = defaults(for: definition)
        switch value {
        case let .bool(flag): store.set(flag, forKey: definition.key)
        case let .int(number): store.set(number, forKey: definition.key)
        case let .double(number): store.set(number, forKey: definition.key)
        case let .string(text): store.set(text, forKey: definition.key)
        case let .array(items):
            store.set(
                items.compactMap { item -> String? in
                    guard case let .string(text) = item else { return nil }
                    return text
                }, forKey: definition.key)
        case .null:
            store.removeObject(forKey: definition.key)
        case .object:
            throw CLIFailure("\(definition.key) cannot be set from the command line")
        }
        store.synchronize()
    }

    public func unset(_ definition: SettingDefinition) throws {
        guard !definition.readOnly else {
            throw CLIFailure("\(definition.key) is read only")
        }
        let store = defaults(for: definition)
        store.removeObject(forKey: definition.key)
        store.synchronize()
    }

    public func snapshot(_ definitions: [SettingDefinition]) -> JSONValue {
        var fields: [String: JSONValue] = [:]
        for definition in definitions {
            fields[definition.key] = value(for: definition)
        }
        return .object(fields)
    }

    public func describe(_ definition: SettingDefinition) -> JSONValue {
        .object([
            "key": .string(definition.key),
            "type": .string(definition.type.rawValue),
            "group": .string(definition.group),
            "scope": .string(definition.scope.rawValue),
            "summary": .string(definition.summary),
            "allowed": .strings(definition.allowed),
            "readOnly": .bool(definition.readOnly),
            "isSet": .bool(isSet(definition)),
            "value": value(for: definition),
            "default": definition.fallback,
        ])
    }

    public static func announceChange() {
        AppBridge.post(IPC.Name.settingsChanged)
    }

    private static func encode(_ object: Any) -> JSONValue {
        switch object {
        case let value as Bool: return .bool(value)
        case let value as Int: return .int(value)
        case let value as Double: return .double(value)
        case let value as String: return .string(value)
        case let value as [Any]: return .array(value.map(encode))
        case let value as [String: Any]:
            return .object(value.mapValues(encode))
        default: return .string(String(describing: object))
        }
    }
}
