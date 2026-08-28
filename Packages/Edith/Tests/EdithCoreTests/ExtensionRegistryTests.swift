import Testing

@testable import EdithCore

@Suite struct ExtensionRegistryTests {
    @Test func identifiersAndDefaultsKeysAreUnique() {
        let entries = ExtensionRegistry.entries

        #expect(Set(entries.map(\.id)).count == entries.count)
        #expect(Set(entries.map(\.defaultsKey)).count == entries.count)
    }

    @Test func identifiersMatchPreUtilityBaseline() {
        #expect(
            ExtensionRegistry.entries.map(\.id) == [
                "attention", "usage", "herdr", "quinjet", "system", "machines", "companion",
                "systemStats", "micMute", "lidAwake", "music", "audioControls", "calendar",
                "notchShelf", "clipboard", "focusDim", "presenter", "colorPicker",
            ])
    }

    @Test func toolRequirementsUsePortableIdentifiers() {
        let requiredByExtension = Dictionary(
            uniqueKeysWithValues: ExtensionRegistry.entries.map { ($0.id, $0.requiredToolIDs) })
        let optionalByExtension = Dictionary(
            uniqueKeysWithValues: ExtensionRegistry.entries.map { ($0.id, $0.optionalToolIDs) })

        #expect(requiredByExtension["usage"] == ["claude", "codex"])
        #expect(requiredByExtension["music"]?.isEmpty == true)
        #expect(optionalByExtension["music"] == ["yt-dlp"])
        #expect(requiredByExtension["quinjet"] == ["quinjet"])
    }
}
