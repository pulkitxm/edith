import Testing

@testable import EdithCore

@Suite struct ExtensionRegistryTests {
    @Test func identifiersAndDefaultsKeysAreUnique() {
        let entries = ExtensionRegistry.entries

        #expect(Set(entries.map(\.id)).count == entries.count)
        #expect(Set(entries.map(\.defaultsKey)).count == entries.count)
    }

    @Test func identifiersMatchCurrentBaseline() {
        #expect(
            ExtensionRegistry.entries.map(\.id) == [
                "usage", "herdr", "quinjet", "companion",
                "appMaintenance", "homebrew", "cleaner",
                "system", "lidAwake", "systemStats", "micMute",
                "clipboard", "emoji", "colorPicker", "keystrokeHighlight", "focusDim", "presenter",
                "music", "downloads", "notchShelf", "audioMixer", "calendar",
                "database", "attention", "seoAudit",
            ])
    }

    @Test func everySuiteOwnsAtLeastOneAbility() {
        for suite in SuiteRegistry.suites {
            #expect(!SuiteRegistry.abilities(in: suite.id).isEmpty)
            #expect(!suite.title.isEmpty)
            #expect(!suite.subtitle.isEmpty)
            #expect(!suite.defaultsKey.isEmpty)
        }
        #expect(Set(SuiteRegistry.suites.map(\.id)) == Set(SuiteID.allCases))
    }

    @Test func onlyTheAgentsSuiteDeclaresAFleetDependency() {
        let requiring = SuiteRegistry.suites.filter(\.requiresFleet).map(\.id)
        #expect(requiring == [.agents])
    }

    @Test func toolRequirementsUsePortableIdentifiers() {
        let requiredByExtension = Dictionary(
            uniqueKeysWithValues: ExtensionRegistry.entries.map { ($0.id, $0.requiredToolIDs) })
        let optionalByExtension = Dictionary(
            uniqueKeysWithValues: ExtensionRegistry.entries.map { ($0.id, $0.optionalToolIDs) })

        #expect(requiredByExtension["usage"] == ["claude", "codex"])
        #expect(requiredByExtension["music"]?.isEmpty == true)
        #expect(requiredByExtension["downloads"] == ["yt-dlp"])
        #expect(requiredByExtension["quinjet"] == ["quinjet"])
        #expect(requiredByExtension["homebrew"] == ["homebrew"])
        #expect(optionalByExtension["appMaintenance"] == ["homebrew"])
    }

    @Test func suiteToolsCoverTheirAbilities() {
        for suite in SuiteRegistry.suites {
            let declared = Set(suite.toolIDs)
            let used = Set(
                SuiteRegistry.abilities(in: suite.id).flatMap {
                    $0.requiredToolIDs + $0.optionalToolIDs
                })
            #expect(declared.subtracting(used).subtracting(["mas"]).isEmpty)
        }
    }
}
