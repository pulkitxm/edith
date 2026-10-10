import ArgumentParser
import EdithExtensionCommands
import EdithExtensionSupport
import EdithExtensionUI
import Foundation

enum UsageConfigValueParser {
    static func parse(
        _ raw: String, as type: UsageSettingDefinition.ValueType, allowed: [String]
    ) throws -> JSONValue {
        do {
            return try UsageConfigurationValueParser.parse(raw, as: type, allowed: allowed)
        } catch let error as UsageConfigurationError {
            throw CLIFailure(error.message, hint: error.hint)
        }
    }

    static func boolean(_ raw: String) throws -> Bool {
        do {
            return try UsageConfigurationValueParser.boolean(raw)
        } catch let error as UsageConfigurationError {
            throw CLIFailure(error.message, hint: error.hint)
        }
    }
}

@MainActor struct UsageConfigStore {
    private let executor: UsageConfigurationExecutor

    init(
        shared: UserDefaults? = nil,
        standard: UserDefaults? = nil
    ) {
        let defaults = shared ?? UsageCLIEnvironment.resources?.defaults ?? SharedDefaults.store
        executor = UsageConfigurationExecutor(
            shared: defaults, standard: standard ?? defaults,
            announceChange: { UsageCLIEnvironment.controller?.settingsChanged() })
    }

    func defaults(for definition: UsageSettingDefinition) -> UserDefaults {
        executor.defaults(for: definition)
    }

    func value(for definition: UsageSettingDefinition) -> JSONValue {
        executor.value(for: definition)
    }

    func isSet(_ definition: UsageSettingDefinition) -> Bool { executor.isSet(definition) }

    func set(
        _ value: JSONValue, for definition: UsageSettingDefinition, announce: Bool = false
    )
        throws
    {
        do {
            try executor.set(value, for: definition, announce: announce)
        } catch let error as UsageConfigurationError {
            throw CLIFailure(error.message, hint: error.hint)
        }
    }

    func unset(_ definition: UsageSettingDefinition, announce: Bool = false) throws {
        do {
            try executor.unset(definition, announce: announce)
        } catch let error as UsageConfigurationError {
            throw CLIFailure(error.message, hint: error.hint)
        }
    }

    func snapshot(_ definitions: [UsageSettingDefinition]) -> JSONValue {
        executor.snapshot(definitions)
    }

    func describe(_ definition: UsageSettingDefinition) -> JSONValue {
        executor.describe(definition)
    }

    static func announceChange() {
        UsageCLIEnvironment.controller?.settingsChanged()
    }
}
