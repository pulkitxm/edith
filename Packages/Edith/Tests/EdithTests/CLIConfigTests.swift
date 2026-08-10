import Foundation
import Testing

@testable import EdithCLI
@testable import EdithHelper
@testable import EdithKit

@Suite struct CLIConfigTests {
    static func scratch(_ name: String) -> UserDefaults {
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func everyCatalogKeyIsOneTheAppActuallyBacksUp() {
        let covered = Set(SettingsBackup.backedKeys).union(SettingsBackup.deviceLocalKeys)
        let unknown = Set(ConfigCatalog.keys).subtracting(covered)
        #expect(unknown.isEmpty, "catalog names settings the app does not persist: \(unknown)")
    }

    @Test func catalogScopeMatchesTheSuiteTheAppReads() {
        for definition in ConfigCatalog.settings where definition.scope == .shared {
            #expect(
                SettingsBackup.sharedKeys.contains(definition.key)
                    || SettingsBackup.deviceLocalKeys.contains(definition.key),
                "\(definition.key) is marked shared but the app does not read it there")
        }
        for definition in ConfigCatalog.settings where definition.scope == .standard {
            #expect(
                !SettingsBackup.sharedKeys.contains(definition.key),
                "\(definition.key) is marked standard but the app reads the shared suite")
        }
    }

    @Test func everyExtensionCanBeToggledFromTheCommandLine() {
        for entry in ExtensionRegistry.entries {
            #expect(
                ConfigCatalog.definition(for: entry.defaultsKey) != nil,
                "\(entry.id) has no catalog entry, so ed config cannot reach it")
        }
    }

    @Test func groupsAreDeclaredForEverySetting() {
        for definition in ConfigCatalog.settings {
            #expect(
                ConfigCatalog.groups.contains(definition.group),
                "\(definition.key) is in undeclared group \(definition.group)")
        }
    }

    @Test func keysAreUnique() {
        #expect(Set(ConfigCatalog.keys).count == ConfigCatalog.keys.count)
    }

    @Test func booleanParsingAcceptsTheUsualSpellings() throws {
        for text in ["true", "yes", "on", "1", "enabled"] {
            let parsed = try ConfigValueParser.boolean(text)
            #expect(parsed)
        }
        for text in ["false", "no", "off", "0", "disabled"] {
            let parsed = try ConfigValueParser.boolean(text)
            #expect(!parsed)
        }
        #expect(throws: CLIFailure.self) { try ConfigValueParser.boolean("maybe") }
    }

    @Test func settingAnEnumeratedValueRejectsAnythingOutsideTheAllowedSet() throws {
        #expect(throws: CLIFailure.self) {
            try ConfigValueParser.parse("elsewhere", as: .string, allowed: ["claude", "codex"])
        }
        let accepted = try ConfigValueParser.parse(
            "codex", as: .string, allowed: ["claude", "codex"])
        #expect(accepted == .string("codex"))
    }

    @Test func numbersMustParse() throws {
        #expect(throws: CLIFailure.self) {
            try ConfigValueParser.parse("soon", as: .int, allowed: [])
        }
        let whole = try ConfigValueParser.parse("70", as: .int, allowed: [])
        let fractional = try ConfigValueParser.parse("0.9", as: .number, allowed: [])
        #expect(whole == .int(70))
        #expect(fractional == .double(0.9))
    }

    @Test func valuesRoundTripThroughTheStore() throws {
        let defaults = Self.scratch("test.cli.roundtrip")
        let store = ConfigStore(shared: defaults, standard: defaults)
        let boolean = ConfigCatalog.definition(for: "preventSleep")!
        #expect(store.value(for: boolean) == .bool(false))
        try store.set(.bool(true), for: boolean)
        #expect(store.value(for: boolean) == .bool(true))
        #expect(store.isSet(boolean))
        try store.unset(boolean)
        #expect(store.value(for: boolean) == .bool(false))
        #expect(!store.isSet(boolean))

        let number = ConfigCatalog.definition(for: "warnPercent")!
        try store.set(.int(72), for: number)
        #expect(store.value(for: number) == .int(72))

        let list = ConfigCatalog.definition(for: "cleanerSelectedDrives")!
        try store.set(.strings(["/", "/Volumes/Data"]), for: list)
        #expect(store.value(for: list) == .strings(["/", "/Volumes/Data"]))
        defaults.removePersistentDomain(forName: "test.cli.roundtrip")
    }

    @Test func readOnlySettingsRefuseWrites() {
        let defaults = Self.scratch("test.cli.readonly")
        let store = ConfigStore(shared: defaults, standard: defaults)
        let granted = ConfigCatalog.definition(for: "permCalendarGranted")!
        #expect(granted.readOnly)
        #expect(throws: CLIFailure.self) { try store.set(.bool(true), for: granted) }
        defaults.removePersistentDomain(forName: "test.cli.readonly")
    }

    @Test func scopeRoutesWritesToTheRightSuite() throws {
        let shared = Self.scratch("test.cli.shared")
        let standard = Self.scratch("test.cli.standard")
        let store = ConfigStore(shared: shared, standard: standard)
        try store.set(.double(0.4), for: ConfigCatalog.definition(for: "musicVolume")!)
        #expect(standard.object(forKey: "musicVolume") != nil)
        #expect(shared.object(forKey: "musicVolume") == nil)
        try store.set(.bool(true), for: ConfigCatalog.definition(for: "preventSleep")!)
        #expect(shared.object(forKey: "preventSleep") != nil)
        shared.removePersistentDomain(forName: "test.cli.shared")
        standard.removePersistentDomain(forName: "test.cli.standard")
    }

    @Test func describeCarriesEnoughForAnAgentToActOnIt() {
        let defaults = Self.scratch("test.cli.describe")
        let store = ConfigStore(shared: defaults, standard: defaults)
        let described = store.describe(ConfigCatalog.definition(for: "limitsProvider")!)
        guard case let .object(fields) = described else {
            Issue.record("describe should be an object")
            return
        }
        #expect(fields["key"] == .string("limitsProvider"))
        #expect(fields["type"] == .string("string"))
        #expect(fields["allowed"] == .strings(["claude", "codex"]))
        #expect(fields["isSet"] == .bool(false))
        defaults.removePersistentDomain(forName: "test.cli.describe")
    }

    @Test func schemaDescribesEveryWritableSettingAndNothingElse() {
        guard case let .object(document) = ConfigSchema.document(),
            case let .object(properties)? = document["properties"]
        else {
            Issue.record("schema should be an object with properties")
            return
        }
        let writable = ConfigCatalog.settings.filter { !$0.readOnly }
        #expect(properties.count == writable.count)
        for definition in writable {
            #expect(properties[definition.key] != nil, "\(definition.key) is missing")
        }
        #expect(document["additionalProperties"] == .bool(false))
        #expect(document["type"] == .string("object"))
    }

    @Test func schemaTypesFollowTheCatalog() {
        let property = ConfigSchema.property(ConfigCatalog.definition(for: "warnPercent")!)
        guard case let .object(fields) = property else {
            Issue.record("property should be an object")
            return
        }
        #expect(fields["type"] == .string("integer"))
        #expect(fields["default"] == .int(60))
    }
}

@Suite struct CLIConfigImportComparisonTests {
    @Test func reimportingAFreshExportChangesNothing() async throws {
        try await CLIProbe.inWorld { world in
            world.shared.set(71, forKey: "warnPercent")
            let exported = await CLIProbe.capture(["config", "export"])
            let file = world.sandbox.appendingPathComponent("export.json")
            try Data(exported.stdout.utf8).write(to: file)
            let dry = await CLIProbe.capture([
                "config", "import", file.path, "--dry-run", "--json",
            ])
            #expect(dry.code == 0)
            #expect((dry.object?["applied"] as? [Any])?.isEmpty == true)
            #expect((dry.object?["unchanged"] as? [Any])?.isEmpty == false)
        }
    }

    @Test func aSettingThatReallyDiffersIsStillReported() async throws {
        try await CLIProbe.inWorld { world in
            world.shared.set(60, forKey: "warnPercent")
            let file = world.sandbox.appendingPathComponent("one.json")
            try Data("{\"warnPercent\": 80}".utf8).write(to: file)
            let dry = await CLIProbe.capture([
                "config", "import", file.path, "--dry-run", "--json",
            ])
            #expect((dry.object?["applied"] as? [String]) == ["warnPercent"])
            #expect(world.shared.integer(forKey: "warnPercent") == 60)
        }
    }
}

@Suite struct ClipboardTextClassificationTests {
    private func entry(ext: String, types: [String]) -> ClipboardEntry {
        ClipboardEntry(
            sha256: "abc", types: types, ext: ext, sourceApp: nil, sourceBundleID: nil,
            size: 3, preview: "hi")
    }

    @Test func aTextExtensionIsTextWhateverUTIWasStoredWithIt() {
        for uti in ["public.url", "org.chromium.source-url", "dyn.ah62d4rv4gu81y3", "public.text"] {
            let row = entry(ext: "txt", types: [uti])
            #expect(row.isTextual, "txt with \(uti) reported as \(row.kind)")
        }
    }

    @Test func theFlagAgreesWithWhetherTheTextCanBeRead() {
        let data = Data("hello".utf8)
        for ext in ["txt", "json", "xml", "sql", "csv", "yaml"] {
            let row = entry(ext: ext, types: ["public.data"])
            #expect(row.isTextual)
            #expect(ClipboardRepository.plainText(for: row, data: data) != nil)
        }
        for ext in ["png", "url", "files", "zip"] {
            let row = entry(ext: ext, types: ["public.data"])
            #expect(!row.isTextual)
            #expect(ClipboardRepository.plainText(for: row, data: data) == nil)
        }
    }

    @Test func anUnknownExtensionIsNotDecodedAsTextByAccident() {
        let row = entry(ext: "sqlite3", types: ["public.data"])
        #expect(!row.isTextual)
        #expect(ClipboardRepository.plainText(for: row, data: Data("hi".utf8)) == nil)
    }
}
