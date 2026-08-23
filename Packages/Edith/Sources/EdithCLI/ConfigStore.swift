import EdithKit
import Foundation

public enum ConfigValueParser {
    public static func parse(
        _ raw: String, as type: SettingDefinition.ValueType, allowed: [String]
    ) throws -> JSONValue {
        do {
            return try ConfigurationValueParser.parse(raw, as: type, allowed: allowed)
        } catch let error as ConfigurationError {
            throw CLIFailure(error.message, hint: error.hint)
        }
    }

    public static func boolean(_ raw: String) throws -> Bool {
        do {
            return try ConfigurationValueParser.boolean(raw)
        } catch let error as ConfigurationError {
            throw CLIFailure(error.message, hint: error.hint)
        }
    }
}

public struct ConfigStore {
    private let executor: ConfigurationExecutor

    public init(
        shared: UserDefaults = CLIEnvironment.sharedDefaults,
        standard: UserDefaults = CLIEnvironment.standardDefaults
    ) {
        executor = ConfigurationExecutor(
            shared: shared, standard: standard,
            announceChange: { CLIEnvironment.deliver(IPC.Name.settingsChanged, nil) })
    }

    public func defaults(for definition: SettingDefinition) -> UserDefaults {
        executor.defaults(for: definition)
    }

    public func value(for definition: SettingDefinition) -> JSONValue {
        executor.value(for: definition)
    }

    public func isSet(_ definition: SettingDefinition) -> Bool { executor.isSet(definition) }

    public func set(_ value: JSONValue, for definition: SettingDefinition, announce: Bool = true)
        throws
    {
        do {
            try executor.set(value, for: definition, announce: announce)
        } catch let error as ConfigurationError {
            throw CLIFailure(error.message, hint: error.hint)
        }
    }

    public func unset(_ definition: SettingDefinition, announce: Bool = true) throws {
        do {
            try executor.unset(definition, announce: announce)
        } catch let error as ConfigurationError {
            throw CLIFailure(error.message, hint: error.hint)
        }
    }

    public func snapshot(_ definitions: [SettingDefinition]) -> JSONValue {
        executor.snapshot(definitions)
    }

    public func describe(_ definition: SettingDefinition) -> JSONValue {
        executor.describe(definition)
    }

    public static func announceChange() {
        CLIEnvironment.deliver(IPC.Name.settingsChanged, nil)
    }
}
