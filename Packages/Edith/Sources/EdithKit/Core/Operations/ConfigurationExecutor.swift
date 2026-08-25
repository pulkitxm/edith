import EdithCore
import Foundation

public struct ConfigurationError: LocalizedError, Equatable, Sendable {
    public let message: String
    public let hint: String?

    public init(_ message: String, hint: String? = nil) {
        self.message = message
        self.hint = hint
    }

    public var errorDescription: String? { message }
}

public enum ConfigurationValueParser {
    public static func parse(
        _ raw: String, as type: SettingDefinition.ValueType, allowed: [String]
    ) throws -> JSONValue {
        switch type {
        case .bool:
            return .bool(try boolean(raw))
        case .int:
            guard let value = Int(raw.trimmingCharacters(in: .whitespaces)) else {
                throw ConfigurationError("\(raw) is not a whole number")
            }
            return .int(value)
        case .number:
            guard let value = Double(raw.trimmingCharacters(in: .whitespaces)) else {
                throw ConfigurationError("\(raw) is not a number")
            }
            return .double(value)
        case .string, .csv:
            guard allowed.isEmpty || allowed.contains(raw) else {
                throw ConfigurationError(
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
            throw ConfigurationError(
                "\(type.rawValue) settings cannot be set from the command line",
                hint: "edit it in the app instead")
        }
    }

    public static func boolean(_ raw: String) throws -> Bool {
        switch raw.lowercased() {
        case "1", "true", "yes", "on", "enabled": return true
        case "0", "false", "no", "off", "disabled": return false
        default: throw ConfigurationError("\(raw) is not a boolean, use true or false")
        }
    }

    public static func coerce(_ raw: Any, to definition: SettingDefinition) throws -> JSONValue {
        let value: JSONValue
        switch definition.type {
        case .bool:
            guard let flag = raw as? Bool else {
                throw ConfigurationError("\(definition.key) wants a bool")
            }
            value = .bool(flag)
        case .int:
            guard !(raw is Bool), let number = raw as? NSNumber else {
                throw ConfigurationError("\(definition.key) wants a whole number")
            }
            let integer: Int
            if let exact = Int(number.stringValue) {
                integer = exact
            } else {
                let floating = number.doubleValue
                guard floating.isFinite, floating.rounded() == floating,
                    let exact = Int(exactly: floating)
                else {
                    throw ConfigurationError("\(definition.key) wants a whole number")
                }
                integer = exact
            }
            value = .int(integer)
        case .number:
            guard !(raw is Bool), let number = raw as? NSNumber, number.doubleValue.isFinite else {
                throw ConfigurationError("\(definition.key) wants a number")
            }
            value = .double(number.doubleValue)
        case .string, .csv:
            guard let string = raw as? String else {
                throw ConfigurationError("\(definition.key) wants a string")
            }
            value = .string(string)
        case .stringList:
            guard let strings = raw as? [String] else {
                throw ConfigurationError("\(definition.key) wants an array of strings")
            }
            value = .strings(strings)
        case .map:
            throw ConfigurationError("\(definition.key) cannot be imported")
        }
        try validate(value, for: definition)
        return value
    }

    public static func validate(_ value: JSONValue, for definition: SettingDefinition) throws {
        guard !definition.readOnly else {
            throw ConfigurationError("\(definition.key) is read only")
        }
        let shapeMatches: Bool
        switch (definition.type, value) {
        case (.bool, .bool), (.int, .int), (.number, .double), (.number, .int),
            (.string, .string), (.csv, .string), (.stringList, .array), (_, .null):
            shapeMatches = true
        default:
            shapeMatches = false
        }
        guard shapeMatches else {
            throw ConfigurationError("\(definition.key) wants a \(definition.type.rawValue)")
        }
        if case let .string(text) = value, !definition.allowed.isEmpty,
            !definition.allowed.contains(text)
        {
            throw ConfigurationError(
                "\(text) is not a valid value",
                hint: "allowed: " + definition.allowed.joined(separator: ", "))
        }
        if case let .int(number) = value, let range = definition.integerRange,
            !range.contains(number)
        {
            throw ConfigurationError(
                "\(definition.key) must be from \(range.lowerBound) through \(range.upperBound)")
        }
        if definition.type == .stringList, case let .array(items) = value,
            items.contains(where: {
                guard case .string = $0 else { return true }
                return false
            })
        {
            throw ConfigurationError("\(definition.key) wants an array of strings")
        }
    }
}

public enum ConfigurationOperation: String, CaseIterable, Sendable {
    case list
    case get
    case set
    case unset
    case describe
    case export
    case `import`

    public var descriptor: UserOperationDescriptor {
        let verb = self == .list ? "ls" : rawValue
        let effect: UserOperationEffect =
            self == .set || self == .unset || self == .import
            ? .write : .read
        return UserOperationDescriptor(
            id: UserOperationID(rawValue: "config.\(rawValue)"),
            summary: summary, cli: ["config", verb], effect: effect)
    }

    private var summary: String {
        switch self {
        case .list: return "List persisted Edith configuration."
        case .get: return "Read one Edith configuration value."
        case .set: return "Validate and write one Edith configuration value."
        case .unset: return "Restore one Edith configuration value to its default."
        case .describe: return "Describe one Edith configuration definition."
        case .export: return "Export persisted Edith configuration."
        case .import: return "Validate and import Edith configuration."
        }
    }
}

public struct ConfigurationExecutor {
    private let shared: UserDefaults
    private let standard: UserDefaults
    private let announceChange: () -> Void

    public init(
        shared: UserDefaults = SharedDefaults.store, standard: UserDefaults = .standard,
        announceChange: @escaping () -> Void = { IPC.post(IPC.Name.settingsChanged) }
    ) {
        self.shared = shared
        self.standard = standard
        self.announceChange = announceChange
    }

    public static var application: ConfigurationExecutor { ConfigurationExecutor() }

    public func definition(for key: String) throws -> SettingDefinition {
        guard let definition = ConfigCatalog.definition(for: key) else {
            throw ConfigurationError("no setting named \(key)")
        }
        return definition
    }

    public func defaults(for definition: SettingDefinition) -> UserDefaults {
        definition.scope == .shared ? shared : standard
    }

    public func value(for definition: SettingDefinition) -> JSONValue {
        let store = defaults(for: definition)
        guard let object = store.object(forKey: definition.key) else { return definition.fallback }
        switch definition.type {
        case .bool: return .bool(store.bool(forKey: definition.key))
        case .int: return .int(store.integer(forKey: definition.key))
        case .number: return .double(store.double(forKey: definition.key))
        case .string, .csv: return .optional(store.string(forKey: definition.key))
        case .stringList: return .strings(store.stringArray(forKey: definition.key) ?? [])
        case .map: return Self.encode(object)
        }
    }

    public func value(forKey key: String) throws -> JSONValue {
        value(for: try definition(for: key))
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

    public func set(_ value: JSONValue, for definition: SettingDefinition, announce: Bool = true)
        throws
    {
        try ConfigurationValueParser.validate(value, for: definition)
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
        case .null: store.removeObject(forKey: definition.key)
        case .object: throw ConfigurationError("\(definition.key) cannot be set")
        }
        store.synchronize()
        if announce { announceChange() }
    }

    public func set(_ value: JSONValue, forKey key: String, announce: Bool = true) throws {
        try set(value, for: definition(for: key), announce: announce)
    }

    public func set(_ raw: String, forKey key: String, announce: Bool = true) throws {
        let definition = try definition(for: key)
        let value = try ConfigurationValueParser.parse(
            raw, as: definition.type, allowed: definition.allowed)
        try set(value, for: definition, announce: announce)
    }

    public func set(_ values: [(key: String, value: JSONValue)]) throws {
        let definitions = try values.map { try definition(for: $0.key) }
        for (offset, definition) in definitions.enumerated() {
            try ConfigurationValueParser.validate(values[offset].value, for: definition)
        }
        for (offset, definition) in definitions.enumerated() {
            try set(values[offset].value, for: definition, announce: false)
        }
        if !values.isEmpty { announceChange() }
    }

    public func unset(_ definition: SettingDefinition, announce: Bool = true) throws {
        guard !definition.readOnly else {
            throw ConfigurationError("\(definition.key) is read only")
        }
        let store = defaults(for: definition)
        store.removeObject(forKey: definition.key)
        store.synchronize()
        if announce { announceChange() }
    }

    public func unset(_ key: String, announce: Bool = true) throws {
        try unset(definition(for: key), announce: announce)
    }

    public func snapshot(_ definitions: [SettingDefinition]) -> JSONValue {
        .object(Dictionary(uniqueKeysWithValues: definitions.map { ($0.key, value(for: $0)) }))
    }

    public func describe(_ definition: SettingDefinition) -> JSONValue {
        var fields: [String: JSONValue] = [
            "key": .string(definition.key), "type": .string(definition.type.rawValue),
            "group": .string(definition.group), "scope": .string(definition.scope.rawValue),
            "summary": .string(definition.summary), "allowed": .strings(definition.allowed),
            "readOnly": .bool(definition.readOnly), "isSet": .bool(isSet(definition)),
            "value": value(for: definition), "default": definition.fallback,
        ]
        if let range = definition.integerRange {
            fields["minimum"] = .int(range.lowerBound)
            fields["maximum"] = .int(range.upperBound)
        }
        return .object(fields)
    }

    public func notifyChange() { announceChange() }

    private static func encode(_ object: Any) -> JSONValue {
        switch object {
        case let value as Bool: return .bool(value)
        case let value as Int: return .int(value)
        case let value as Double: return .double(value)
        case let value as String: return .string(value)
        case let value as [Any]: return .array(value.map(encode))
        case let value as [String: Any]: return .object(value.mapValues(encode))
        default: return .string(String(describing: object))
        }
    }
}
