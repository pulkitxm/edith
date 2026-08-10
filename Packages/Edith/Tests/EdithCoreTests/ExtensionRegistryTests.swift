import Testing

@testable import EdithCore

@Suite struct ExtensionRegistryTests {
    @Test func identifiersAndDefaultsKeysAreUnique() {
        let entries = ExtensionRegistry.entries

        #expect(Set(entries.map(\.id)).count == entries.count)
        #expect(Set(entries.map(\.defaultsKey)).count == entries.count)
    }

    @Test func everyExtensionHasAnUbuntuAvailability() {
        let extensionIDs = Set(ExtensionRegistry.entries.map(\.id))
        let diagnosedIDs = Set(
            ExtensionRegistry.entries.compactMap { entry in
                switch entry.availability(on: .ubuntu) {
                case .available, .degraded, .unavailable: entry.id
                }
            })

        #expect(diagnosedIDs == extensionIDs)
    }

    @Test func toolRequirementsUsePortableIdentifiers() {
        let toolsByExtension = Dictionary(
            uniqueKeysWithValues: ExtensionRegistry.entries.map { ($0.id, $0.requiredToolIDs) })

        #expect(toolsByExtension["usage"] == ["claude", "codex"])
        #expect(toolsByExtension["music"] == ["yt-dlp"])
    }
}
