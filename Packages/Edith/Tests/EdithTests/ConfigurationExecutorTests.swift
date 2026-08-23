import Foundation
import Testing

@testable import EdithCLI
@testable import EdithKit

@Suite struct ConfigurationExecutorTests {
    static func stores(_ label: String) -> (UserDefaults, UserDefaults) {
        let sharedName = "test.configuration.\(label).shared"
        let standardName = "test.configuration.\(label).standard"
        let shared = UserDefaults(suiteName: sharedName)!
        let standard = UserDefaults(suiteName: standardName)!
        shared.removePersistentDomain(forName: sharedName)
        standard.removePersistentDomain(forName: standardName)
        return (shared, standard)
    }

    @Test func lookupValidationAndMutationShareOneExecutor() throws {
        let (shared, standard) = Self.stores("mutation")
        var announcements = 0
        let executor = ConfigurationExecutor(
            shared: shared, standard: standard, announceChange: { announcements += 1 })

        let appearance = try executor.definition(for: AppStorageKeys.General.appearance)
        #expect(executor.value(for: appearance) == .string("system"))
        try executor.set("dark", forKey: appearance.key)
        #expect(executor.value(for: appearance) == .string("dark"))
        #expect(announcements == 1)

        #expect(throws: ConfigurationError.self) {
            try executor.set("purple", forKey: appearance.key)
        }
        #expect(executor.value(for: appearance) == .string("dark"))
        #expect(announcements == 1)

        try executor.unset(appearance.key)
        #expect(executor.value(for: appearance) == .string("system"))
        #expect(announcements == 2)
    }

    @Test func scopeAndShapeAreEnforcedForTypedUIWrites() throws {
        let (shared, standard) = Self.stores("scope")
        let executor = ConfigurationExecutor(
            shared: shared, standard: standard, announceChange: {})

        try executor.set(.bool(false), forKey: "SUEnableAutomaticChecks")
        #expect(standard.object(forKey: "SUEnableAutomaticChecks") as? Bool == false)
        #expect(shared.object(forKey: "SUEnableAutomaticChecks") == nil)

        #expect(throws: ConfigurationError.self) {
            try executor.set(.string("false"), forKey: AppStorageKeys.General.preventSleep)
        }
        #expect(shared.object(forKey: AppStorageKeys.General.preventSleep) == nil)
    }

    @Test func importCoercionUsesCatalogValidation() throws {
        let definition = ConfigCatalog.definition(for: AppStorageKeys.Limits.provider)!
        #expect(
            try ConfigurationValueParser.coerce("codex", to: definition) == .string("codex"))
        #expect(throws: ConfigurationError.self) {
            try ConfigurationValueParser.coerce("other", to: definition)
        }
    }

    @Test func everyConfigurationOperationIsRegistered() {
        let descriptors = ConfigurationOperation.allCases.map(\.descriptor)
        #expect(Set(descriptors.map(\.id)).count == descriptors.count)
        #expect(Set(descriptors.map(\.cli)).count == descriptors.count)
        for descriptor in descriptors {
            #expect(UserOperationCatalog.descriptor(id: descriptor.id) == descriptor)
            #expect(UserOperationCatalog.descriptor(cli: descriptor.cli) == descriptor)
        }
        #expect(
            Set(descriptors.filter { $0.effect == .write }.map(\.cli))
                == [["config", "set"], ["config", "unset"], ["config", "import"]])
    }
}

@Suite(.serialized) struct ConfigurationProcessTests {
    @Test func shippedEntrySharesPlainJSONAndFailureContracts() throws {
        let suite = "ConfigurationProcessTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        var environment = ProcessInfo.processInfo.environment
        environment["EDITH_TEST_SHARED_DEFAULTS_SUITE"] = suite

        let plain = try CLIProcessProbe.run(
            ["config", "set", "appearance", "dark"], environment: environment)
        defaults.synchronize()
        #expect(plain.code == 0)
        #expect(plain.stdout == "appearance = dark\n")
        #expect(plain.stderr.isEmpty)
        #expect(defaults.string(forKey: AppStorageKeys.General.appearance) == "dark")

        let json = try CLIProcessProbe.run(
            ["config", "get", "appearance", "--json"], environment: environment)
        #expect(json.code == 0)
        #expect(json.object?["key"] as? String == "appearance")
        #expect(json.object?["value"] as? String == "dark")

        let invalid = try CLIProcessProbe.run(
            ["config", "set", "appearance", "purple"], environment: environment)
        defaults.synchronize()
        #expect(invalid.code == 1)
        #expect(invalid.stdout.isEmpty)
        #expect(invalid.stderr.contains("allowed: system, light, dark"))
        #expect(defaults.string(forKey: AppStorageKeys.General.appearance) == "dark")

        let unset = try CLIProcessProbe.run(
            ["config", "unset", "appearance", "--json"], environment: environment)
        defaults.synchronize()
        #expect(unset.code == 0)
        #expect(unset.object?["value"] as? String == "system")
        #expect(defaults.object(forKey: AppStorageKeys.General.appearance) == nil)
    }
}
