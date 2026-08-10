import Foundation
import Testing

@testable import EdithCLI
@testable import EdithKit

enum CatalogSamples {
    static func writable() -> [SettingDefinition] {
        ConfigCatalog.settings.filter { !$0.readOnly && $0.type != .map }
    }

    static func allowedChoice(_ definition: SettingDefinition) -> String? {
        guard !definition.allowed.isEmpty else { return nil }
        guard case let .string(fallback) = definition.fallback else {
            return definition.allowed.first
        }
        return definition.allowed.first { $0 != fallback } ?? definition.allowed.first
    }

    static func sample(for definition: SettingDefinition) -> String {
        if let choice = allowedChoice(definition) { return choice }
        switch definition.type {
        case .bool: return definition.fallback == .bool(true) ? "false" : "true"
        case .int: return definition.fallback == .int(7) ? "8" : "7"
        case .number: return definition.fallback == .double(0.25) ? "0.5" : "0.25"
        case .string: return "edith-test-value"
        case .csv: return "one,two"
        case .stringList: return "one,two"
        case .map: return ""
        }
    }

    static func expected(for definition: SettingDefinition) -> JSONValue {
        if let choice = allowedChoice(definition) { return .string(choice) }
        switch definition.type {
        case .bool: return .bool(definition.fallback != .bool(true))
        case .int: return .int(definition.fallback == .int(7) ? 8 : 7)
        case .number: return .double(definition.fallback == .double(0.25) ? 0.5 : 0.25)
        case .string: return .string("edith-test-value")
        case .csv: return .string("one,two")
        case .stringList: return .strings(["one", "two"])
        case .map: return .null
        }
    }

    static func rejected(for definition: SettingDefinition) -> String? {
        if !definition.allowed.isEmpty { return "definitely-not-allowed" }
        switch definition.type {
        case .bool: return "maybe"
        case .int: return "seven"
        case .number: return "loads"
        case .string, .csv, .stringList, .map: return nil
        }
    }
}

@Suite struct CLIConfigCatalogTests {
    static func scratch() -> (defaults: UserDefaults, name: String) {
        let name = "test.cli.catalog.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return (defaults, name)
    }

    static func stored(_ suite: (defaults: UserDefaults, name: String), _ key: String) -> Any? {
        suite.defaults.persistentDomain(forName: suite.name)?[key]
    }

    @Test func theCatalogIsBigEnoughToBeTheWholeUI() {
        #expect(ConfigCatalog.settings.count > 150)
    }

    @Test func everySettingParsesSetsReadsBackAndUnsets() throws {
        let suite = Self.scratch()
        let store = ConfigStore(shared: suite.defaults, standard: suite.defaults)
        for definition in CatalogSamples.writable() {
            let parsed = try ConfigValueParser.parse(
                CatalogSamples.sample(for: definition), as: definition.type,
                allowed: definition.allowed)
            #expect(
                parsed == CatalogSamples.expected(for: definition),
                "\(definition.key) parsed to \(parsed)")
            #expect(!store.isSet(definition), "\(definition.key) started out set")
            try store.set(parsed, for: definition)
            #expect(store.isSet(definition), "\(definition.key) did not stick")
            #expect(
                store.value(for: definition) == parsed,
                "\(definition.key) read back as \(store.value(for: definition))")
            try store.unset(definition)
            #expect(!store.isSet(definition), "\(definition.key) survived unset")
            #expect(
                store.value(for: definition) == definition.fallback,
                "\(definition.key) did not fall back to \(definition.fallback)")
        }
    }

    @Test func everySettingRejectsAValueOfTheWrongShape() {
        for definition in CatalogSamples.writable() {
            guard let bad = CatalogSamples.rejected(for: definition) else { continue }
            #expect(
                throws: CLIFailure.self,
                "\(definition.key) accepted \(bad)"
            ) {
                try ConfigValueParser.parse(
                    bad, as: definition.type, allowed: definition.allowed)
            }
        }
    }

    @Test func everyDefaultIsOfTheTypeItsSettingDeclares() {
        for definition in ConfigCatalog.settings {
            switch (definition.type, definition.fallback) {
            case (.bool, .bool), (.int, .int), (.number, .double), (.number, .int),
                (.string, .string), (.csv, .string), (.stringList, .array),
                (.map, .object), (_, .null):
                continue
            default:
                Issue.record(
                    "\(definition.key) is \(definition.type.rawValue) but defaults wrongly")
            }
        }
    }

    @Test func everyEnumeratedSettingDefaultsToOneOfItsOwnValues() {
        for definition in ConfigCatalog.settings where !definition.allowed.isEmpty {
            guard case let .string(fallback) = definition.fallback else { continue }
            #expect(
                definition.allowed.contains(fallback),
                "\(definition.key) defaults to \(fallback), which it does not allow")
        }
    }

    @Test func onlyStringLikeSettingsEnumerateValues() {
        for definition in ConfigCatalog.settings where !definition.allowed.isEmpty {
            #expect(
                definition.type == .string || definition.type == .csv,
                "\(definition.key) is \(definition.type.rawValue) but lists allowed values")
        }
    }

    @Test func everySettingHasASummaryAndAGroup() {
        for definition in ConfigCatalog.settings {
            #expect(!definition.summary.isEmpty, "\(definition.key) has no summary")
            #expect(!definition.group.isEmpty, "\(definition.key) has no group")
        }
    }

    @Test func everyDescribedSettingCarriesTheSameFields() {
        let suite = Self.scratch()
        let store = ConfigStore(shared: suite.defaults, standard: suite.defaults)
        let expected: Set<String> = [
            "key", "type", "group", "scope", "summary", "allowed", "readOnly", "isSet",
            "value", "default",
        ]
        for definition in ConfigCatalog.settings {
            guard case let .object(fields) = store.describe(definition) else {
                Issue.record("\(definition.key) did not describe as an object")
                continue
            }
            #expect(Set(fields.keys) == expected, "\(definition.key) described oddly")
            #expect(fields["key"] == .string(definition.key))
            #expect(fields["type"] == .string(definition.type.rawValue))
        }
    }

    @Test func readOnlySettingsRefuseBothWritesAndUnsets() {
        let suite = Self.scratch()
        let store = ConfigStore(shared: suite.defaults, standard: suite.defaults)
        let locked = ConfigCatalog.settings.filter(\.readOnly)
        #expect(!locked.isEmpty)
        for definition in locked {
            #expect(throws: CLIFailure.self) { try store.set(.bool(true), for: definition) }
            #expect(throws: CLIFailure.self) { try store.unset(definition) }
        }
    }

    @Test func mapSettingsCannotBeWrittenFromTheCommandLine() {
        for definition in ConfigCatalog.settings where definition.type == .map {
            #expect(throws: CLIFailure.self) {
                try ConfigValueParser.parse("{}", as: .map, allowed: [])
            }
        }
    }

    @Test func theSchemaTypeMatchesTheCatalogTypeForEverySetting() {
        let byType: [SettingDefinition.ValueType: String] = [
            .bool: "boolean", .int: "integer", .number: "number", .string: "string",
            .csv: "string", .stringList: "array", .map: "object",
        ]
        for definition in ConfigCatalog.settings where !definition.readOnly {
            guard case let .object(fields) = ConfigSchema.property(definition) else {
                Issue.record("\(definition.key) has no schema property")
                continue
            }
            #expect(
                fields["type"] == .string(byType[definition.type] ?? ""),
                "\(definition.key) schema says \(fields["type"] ?? .null)")
            if !definition.allowed.isEmpty {
                #expect(fields["enum"] == .strings(definition.allowed))
            }
        }
    }

    @Test func exportingThenImportingRestoresEveryValue() throws {
        let suite = Self.scratch()
        let store = ConfigStore(shared: suite.defaults, standard: suite.defaults)
        let settings = CatalogSamples.writable()
        for definition in settings {
            try store.set(CatalogSamples.expected(for: definition), for: definition)
        }
        let snapshot = store.snapshot(settings)
        guard case let .object(fields) = snapshot else {
            Issue.record("a snapshot should be an object")
            return
        }
        #expect(fields.count == settings.count)
        for definition in settings {
            #expect(
                fields[definition.key] == CatalogSamples.expected(for: definition),
                "\(definition.key) exported as \(fields[definition.key] ?? .null)")
        }
    }

    @Test func scopeDecidesWhichSuiteEverySettingLandsIn() throws {
        let shared = Self.scratch()
        let standard = Self.scratch()
        let store = ConfigStore(shared: shared.defaults, standard: standard.defaults)
        for definition in CatalogSamples.writable() {
            try store.set(CatalogSamples.expected(for: definition), for: definition)
            let wanted = definition.scope == .shared ? shared : standard
            let other = definition.scope == .shared ? standard : shared
            #expect(
                Self.stored(wanted, definition.key) != nil,
                "\(definition.key) did not land in its own suite")
            #expect(
                Self.stored(other, definition.key) == nil,
                "\(definition.key) leaked into the other suite")
        }
    }
}

@Suite struct CLIConfigCommandTests {
    @Test func everySettingRoundTripsThroughTheRealCommands() async {
        await CLIProbe.inWorld { world in
            for definition in CatalogSamples.writable() {
                let key = definition.key
                let sample = CatalogSamples.sample(for: definition)
                let set = await CLIProbe.capture(["config", "set", key, sample])
                #expect(set.code == 0, "ed config set \(key) exited \(set.code)")
                let get = await CLIProbe.capture(["config", "get", key, "--json"])
                #expect(get.code == 0, "ed config get \(key) exited \(get.code)")
                guard let object = get.object else {
                    Issue.record("ed config get \(key) --json was not an object")
                    continue
                }
                #expect(object["isSet"] as? Bool == true, "\(key) did not report as set")
                let unset = await CLIProbe.capture(["config", "unset", key, "--json"])
                #expect(unset.code == 0, "ed config unset \(key) exited \(unset.code)")
                #expect(
                    world.shared.persistentDomain(forName: world.suite)?[key] == nil,
                    "\(key) survived unset")
            }
        }
    }

    @Test func everySettingRejectsABadValueThroughTheRealCommand() async {
        await CLIProbe.inWorld { _ in
            for definition in CatalogSamples.writable() {
                guard let bad = CatalogSamples.rejected(for: definition) else { continue }
                let result = await CLIProbe.capture(["config", "set", definition.key, bad])
                #expect(
                    result.code == ExitCodes.failure,
                    "ed config set \(definition.key) \(bad) exited \(result.code)")
                #expect(result.stdout.isEmpty)
            }
        }
    }

    @Test func setAnnouncesTheChangeSoTheAppPicksItUp() async {
        await CLIProbe.inWorld { world in
            _ = await CLIProbe.capture(["config", "set", "preventSleep", "true"])
            #expect(world.postedNames().contains(IPC.Name.settingsChanged.rawValue))
        }
    }

    @Test func listingReportsEverySettingAsOneJSONArray() async {
        let result = await CLIProbe.run(["config", "ls", "--json"])
        #expect(result.code == 0)
        let array = try? #require(result.array)
        #expect(array?.count == ConfigCatalog.settings.count)
    }

    @Test func listingByPrefixNarrowsTheSameWayTheCatalogDoes() async {
        let result = await CLIProbe.run(["config", "ls", "presenter", "--json"])
        #expect(result.code == 0)
        #expect(result.array?.count == ConfigCatalog.matching(prefix: "presenter").count)
    }

    @Test func listingByGroupOnlyShowsThatGroup() async {
        for group in ConfigCatalog.groups {
            let result = await CLIProbe.run(["config", "ls", "--group", group, "--json"])
            #expect(result.code == 0, "group \(group) exited \(result.code)")
            let rows = result.array as? [[String: Any]] ?? []
            #expect(!rows.isEmpty, "group \(group) is empty, so it should not be declared")
            #expect(rows.allSatisfy { $0["group"] as? String == group })
        }
    }

    @Test func changedOnlyListsWhatWasActuallyWritten() async {
        await CLIProbe.inWorld { _ in
            let before = await CLIProbe.capture(["config", "ls", "--changed", "--json"])
            #expect(before.array?.isEmpty == true)
            _ = await CLIProbe.capture(["config", "set", "preventSleep", "true"])
            let after = await CLIProbe.capture(["config", "ls", "--changed", "--json"])
            #expect(after.array?.count == 1)
        }
    }

    @Test func exportOnlyCarriesTheSettingsThatWereChanged() async {
        await CLIProbe.inWorld { _ in
            let empty = await CLIProbe.capture(["config", "export"])
            #expect(empty.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "{}")
            _ = await CLIProbe.capture(["config", "set", "warnPercent", "72"])
            let one = await CLIProbe.capture(["config", "export"])
            #expect(one.object?.count == 1)
            #expect(one.object?["warnPercent"] as? Int == 72)
        }
    }

    @Test func exportWithDefaultsCarriesEveryWritableSetting() async {
        let result = await CLIProbe.run(["config", "export", "--defaults"])
        #expect(result.code == 0)
        #expect(result.object?.count == CatalogSamples.writable().count)
    }

    @Test func exportedDocumentsImportBackCleanly() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ed-roundtrip-\(UUID().uuidString).json")
        await CLIProbe.inWorld { _ in
            _ = await CLIProbe.capture(["config", "set", "warnPercent", "72"])
            _ = await CLIProbe.capture(["config", "set", "preventSleep", "true"])
            let exported = await CLIProbe.capture(["config", "export"])
            try? Data(exported.stdout.utf8).write(to: url)
            let imported = await CLIProbe.capture(["config", "import", url.path, "--json"])
            #expect(imported.code == 0)
            #expect((imported.object?["applied"] as? [Any])?.isEmpty == true)
            #expect((imported.object?["unchanged"] as? [Any])?.count == 2)
            #expect((imported.object?["skipped"] as? [Any])?.isEmpty == true)
        }
        try? FileManager.default.removeItem(at: url)
    }

    @Test func aDryRunImportChangesNothing() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ed-dryrun-\(UUID().uuidString).json")
        try Data(#"{"warnPercent": 81}"#.utf8).write(to: url)
        await CLIProbe.inWorld { world in
            let result = await CLIProbe.capture([
                "config", "import", url.path, "--dry-run", "--json",
            ])
            #expect(result.code == 0)
            #expect(result.object?["dryRun"] as? Bool == true)
            #expect(world.shared.persistentDomain(forName: world.suite)?["warnPercent"] == nil)
        }
        try? FileManager.default.removeItem(at: url)
    }

    @Test func importSkipsKeysItDoesNotOwnRatherThanFailing() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ed-skip-\(UUID().uuidString).json")
        try Data(#"{"notASetting": 1, "permCalendarGranted": true}"#.utf8).write(to: url)
        await CLIProbe.inWorld { _ in
            let result = await CLIProbe.capture(["config", "import", url.path, "--json"])
            #expect(result.code == 0)
            let skipped = result.object?["skipped"] as? [String] ?? []
            #expect(Set(skipped) == ["notASetting", "permCalendarGranted"])
        }
        try? FileManager.default.removeItem(at: url)
    }

    @Test func importRefusesAValueOfTheWrongType() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ed-wrongtype-\(UUID().uuidString).json")
        try Data(#"{"warnPercent": "seventy"}"#.utf8).write(to: url)
        await CLIProbe.inWorld { world in
            let result = await CLIProbe.capture(["config", "import", url.path, "--json"])
            #expect((result.object?["skipped"] as? [String]) == ["warnPercent"])
            #expect(world.shared.persistentDomain(forName: world.suite)?["warnPercent"] == nil)
        }
        try? FileManager.default.removeItem(at: url)
    }

    @Test func describeAndGetAgreeOnTheFacts() async {
        await CLIProbe.inWorld { _ in
            _ = await CLIProbe.capture(["config", "set", "limitsProvider", "codex"])
            let described = await CLIProbe.capture([
                "config", "describe", "limitsProvider", "--json",
            ])
            let fetched = await CLIProbe.capture(["config", "get", "limitsProvider", "--json"])
            #expect(described.stdout == fetched.stdout)
            let human = await CLIProbe.capture(["config", "get", "limitsProvider"])
            #expect(human.stdout == "codex\n")
        }
    }

    @Test func theSchemaIsOneJSONDocumentCoveringEveryWritableSetting() async {
        let result = await CLIProbe.run(["schema"])
        #expect(result.code == 0)
        let object = try? #require(result.object)
        let properties = object?["properties"] as? [String: Any] ?? [:]
        #expect(properties.count == ConfigCatalog.settings.filter { !$0.readOnly }.count)
        #expect(object?["additionalProperties"] as? Bool == false)
    }
}
