import Testing

@testable import EdithCore

@Suite struct ExtensionRegistryTests {
    @Test func identifiersAndDefaultsKeysAreUnique() {
        let entries = ExtensionRegistry.entries

        #expect(Set(entries.map(\.id)).count == entries.count)
        #expect(Set(entries.map(\.defaultsKey)).count == entries.count)
    }

    @Test func toolRequirementsUsePortableIdentifiers() {
        let toolsByExtension = Dictionary(
            uniqueKeysWithValues: ExtensionRegistry.entries.map { ($0.id, $0.requiredToolIDs) })

        #expect(toolsByExtension["usage"] == ["claude", "codex"])
        #expect(toolsByExtension["music"] == ["yt-dlp"])
    }
}
