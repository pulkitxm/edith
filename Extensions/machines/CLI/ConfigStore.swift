import EdithExtensionCommands
import EdithExtensionSupport
import Foundation

enum ConfigValueParser {
    static func parse(
        _ raw: String, as type: SettingDefinition.ValueType, allowed: [String]
    ) throws -> JSONValue {
        do {
            return try ConfigurationValueParser.parse(raw, as: type, allowed: allowed)
        } catch let error as ConfigurationError {
            throw CLIFailure(error.message, hint: error.hint)
        }
    }

    static func boolean(_ raw: String) throws -> Bool {
        do {
            return try ConfigurationValueParser.boolean(raw)
        } catch let error as ConfigurationError {
            throw CLIFailure(error.message, hint: error.hint)
        }
    }
}

struct ConfigStore {
    private let executor: ConfigurationExecutor

    init(
        shared: UserDefaults = SharedDefaults.store,
        standard: UserDefaults = SharedDefaults.store
    ) {
        executor = ConfigurationExecutor(
            shared: shared, standard: standard,
            announceChange: { MachinesCLIEnvironment.changed() })
    }

    func defaults(for definition: SettingDefinition) -> UserDefaults {
        executor.defaults(for: definition)
    }

    func value(for definition: SettingDefinition) -> JSONValue {
        executor.value(for: definition)
    }

    func isSet(_ definition: SettingDefinition) -> Bool { executor.isSet(definition) }

    func set(_ value: JSONValue, for definition: SettingDefinition, announce: Bool = false)
        throws
    {
        do {
            try executor.set(value, for: definition, announce: announce)
        } catch let error as ConfigurationError {
            throw CLIFailure(error.message, hint: error.hint)
        }
    }

    func unset(_ definition: SettingDefinition, announce: Bool = false) throws {
        do {
            try executor.unset(definition, announce: announce)
        } catch let error as ConfigurationError {
            throw CLIFailure(error.message, hint: error.hint)
        }
    }

    func snapshot(_ definitions: [SettingDefinition]) -> JSONValue {
        executor.snapshot(definitions)
    }

    func describe(_ definition: SettingDefinition) -> JSONValue {
        executor.describe(definition)
    }

    static func announceChange() {
        MachinesCLIEnvironment.changed()
    }
}
