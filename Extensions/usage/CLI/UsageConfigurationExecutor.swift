import ArgumentParser
import EdithExtensionCommands
import EdithExtensionSupport
import EdithExtensionUI
import Foundation
struct UsageConfigurationError: LocalizedError, Equatable, Sendable {
    let message: String
    let hint: String?

    init(_ message: String, hint: String? = nil) {
        self.message = message
        self.hint = hint
    }

    var errorDescription: String? { message }
}

enum UsageConfigurationValueParser {
    static func parse(
        _ raw: String, as type: UsageSettingDefinition.ValueType, allowed: [String]
    ) throws -> JSONValue {
        switch type {
        case .bool:
            return .bool(try boolean(raw))
        case .int:
            guard let value = Int(raw.trimmingCharacters(in: .whitespaces)) else {
                throw UsageConfigurationError("\(raw) is not a whole number")
            }
            return .int(value)
        case .number:
            guard let value = Double(raw.trimmingCharacters(in: .whitespaces)) else {
                throw UsageConfigurationError("\(raw) is not a number")
            }
            return .double(value)
        case .string, .csv:
            guard allowed.isEmpty || allowed.contains(raw) else {
                throw UsageConfigurationError(
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
            throw UsageConfigurationError(
                "\(type.rawValue) settings cannot be set from the command line",
                hint: "edit it in the app instead")
        }
    }

    static func boolean(_ raw: String) throws -> Bool {
        switch raw.lowercased() {
        case "1", "true", "yes", "on", "enabled": return true
        case "0", "false", "no", "off", "disabled": return false
        default: throw UsageConfigurationError("\(raw) is not a boolean, use true or false")
        }
    }

    static func coerce(_ raw: Any, to definition: UsageSettingDefinition) throws -> JSONValue {
        let value: JSONValue
        switch definition.type {
        case .bool:
            guard let flag = raw as? Bool else {
                throw UsageConfigurationError("\(definition.key) wants a bool")
            }
            value = .bool(flag)
        case .int:
            guard !(raw is Bool), let number = raw as? NSNumber else {
                throw UsageConfigurationError("\(definition.key) wants a whole number")
            }
            let integer: Int
            if let exact = Int(number.stringValue) {
                integer = exact
            } else {
                let floating = number.doubleValue
                guard floating.isFinite, floating.rounded() == floating,
                    let exact = Int(exactly: floating)
                else {
                    throw UsageConfigurationError("\(definition.key) wants a whole number")
                }
                integer = exact
            }
            value = .int(integer)
        case .number:
            guard !(raw is Bool), let number = raw as? NSNumber, number.doubleValue.isFinite else {
                throw UsageConfigurationError("\(definition.key) wants a number")
            }
            value = .double(number.doubleValue)
        case .string, .csv:
            guard let string = raw as? String else {
                throw UsageConfigurationError("\(definition.key) wants a string")
            }
            value = .string(string)
        case .stringList:
            guard let strings = raw as? [String] else {
                throw UsageConfigurationError("\(definition.key) wants an array of strings")
            }
            value = .strings(strings)
        case .map:
            throw UsageConfigurationError("\(definition.key) cannot be imported")
        }
        try validate(value, for: definition)
        return value
    }

    static func validate(_ value: JSONValue, for definition: UsageSettingDefinition) throws {
        guard !definition.readOnly else {
            throw UsageConfigurationError("\(definition.key) is read only")
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
            throw UsageConfigurationError("\(definition.key) wants a \(definition.type.rawValue)")
        }
        if case let .string(text) = value, !definition.allowed.isEmpty,
            !definition.allowed.contains(text)
        {
            throw UsageConfigurationError(
                "\(text) is not a valid value",
                hint: "allowed: " + definition.allowed.joined(separator: ", "))
        }
        if case let .int(number) = value, let range = definition.integerRange,
            !range.contains(number)
        {
            throw UsageConfigurationError(
                "\(definition.key) must be from \(range.lowerBound) through \(range.upperBound)")
        }
        if definition.type == .stringList, case let .array(items) = value,
            items.contains(where: {
                guard case .string = $0 else { return true }
                return false
            })
        {
            throw UsageConfigurationError("\(definition.key) wants an array of strings")
        }
    }
}

@MainActor struct UsageConfigurationExecutor {
    private let shared: UserDefaults
    private let standard: UserDefaults
    private let announceChange: @MainActor () -> Void

    init(
        shared: UserDefaults = SharedDefaults.store, standard: UserDefaults = SharedDefaults.store,
        announceChange: @escaping @MainActor () -> Void = {
            UsageCLIEnvironment.controller?.settingsChanged()
        }
    ) {
        self.shared = shared
        self.standard = standard
        self.announceChange = announceChange
    }

    static var application: UsageConfigurationExecutor { UsageConfigurationExecutor() }

    func definition(for key: String) throws -> UsageSettingDefinition {
        guard let definition = UsageConfigCatalog.definition(for: key) else {
            throw UsageConfigurationError("no setting named \(key)")
        }
        return definition
    }

    func defaults(for definition: UsageSettingDefinition) -> UserDefaults {
        definition.scope == .shared ? shared : standard
    }

    func value(for definition: UsageSettingDefinition) -> JSONValue {
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

    func value(forKey key: String) throws -> JSONValue {
        value(for: try definition(for: key))
    }

    func isSet(_ definition: UsageSettingDefinition) -> Bool {
        guard let stored = defaults(for: definition).object(forKey: definition.key) else {
            return false
        }
        let registered = shared.volatileDomain(
            forName: UserDefaults.registrationDomain)
        guard let registeredValue = registered[definition.key] else { return true }
        return !(stored as AnyObject).isEqual(registeredValue)
    }

    func set(
        _ value: JSONValue, for definition: UsageSettingDefinition, announce: Bool = true
    )
        throws
    {
        try UsageConfigurationValueParser.validate(value, for: definition)
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
        case .object: throw UsageConfigurationError("\(definition.key) cannot be set")
        }
        store.synchronize()
        if announce { announceChange() }
    }

    func set(_ value: JSONValue, forKey key: String, announce: Bool = true) throws {
        try set(value, for: definition(for: key), announce: announce)
    }

    func set(_ raw: String, forKey key: String, announce: Bool = true) throws {
        let definition = try definition(for: key)
        let value = try UsageConfigurationValueParser.parse(
            raw, as: definition.type, allowed: definition.allowed)
        try set(value, for: definition, announce: announce)
    }

    func set(_ values: [(key: String, value: JSONValue)]) throws {
        let definitions = try values.map { try definition(for: $0.key) }
        for (offset, definition) in definitions.enumerated() {
            try UsageConfigurationValueParser.validate(values[offset].value, for: definition)
        }
        for (offset, definition) in definitions.enumerated() {
            try set(values[offset].value, for: definition, announce: false)
        }
        if !values.isEmpty { announceChange() }
    }

    func unset(_ definition: UsageSettingDefinition, announce: Bool = true) throws {
        guard !definition.readOnly else {
            throw UsageConfigurationError("\(definition.key) is read only")
        }
        let store = defaults(for: definition)
        store.removeObject(forKey: definition.key)
        store.synchronize()
        if announce { announceChange() }
    }

    func unset(_ key: String, announce: Bool = true) throws {
        try unset(definition(for: key), announce: announce)
    }

    func snapshot(_ definitions: [UsageSettingDefinition]) -> JSONValue {
        .object(Dictionary(uniqueKeysWithValues: definitions.map { ($0.key, value(for: $0)) }))
    }

    func describe(_ definition: UsageSettingDefinition) -> JSONValue {
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

    func notifyChange() { announceChange() }

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
