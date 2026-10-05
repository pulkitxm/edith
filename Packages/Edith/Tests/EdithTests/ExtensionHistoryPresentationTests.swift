import AppKit
import SwiftUI
import Testing

@testable import Edith
@testable import EdithHelper
@testable import EdithKit

@MainActor @Suite(.serialized)
struct ExtensionHistoryPresentationTests {
    @Test func clipboardFailureCanBeRetriedWithoutLosingHistory() async {
        let fixture = ClipboardRecentFixture()
        let model = ClipboardRecentModel { try await fixture.load() }
        await model.refresh()
        #expect(model.entries.count == 1)
        await model.refresh()
        #expect(model.error != nil)
        #expect(model.entries.count == 1)
        #expect(!model.loading)
        await model.refresh()
        #expect(model.error == nil)
        #expect(model.entries.isEmpty)
        #expect(!model.loading)
    }

    @Test func emojiHistoryRefreshesWhileItsPageIsMounted() async throws {
        let keys = [
            AppStorageKeys.Emoji.enabled, AppStorageKeys.Emoji.frequentCount,
            AppStorageKeys.Emoji.usage,
        ]
        let previous = keys.map { SharedDefaults.store.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, previous) { SharedDefaults.store.set(value, forKey: key) }
        }
        SharedDefaults.store.set(true, forKey: AppStorageKeys.Emoji.enabled)
        SharedDefaults.store.set(10, forKey: AppStorageKeys.Emoji.frequentCount)
        SharedDefaults.store.removeObject(forKey: AppStorageKeys.Emoji.usage)
        let host = try auditHost(
            Form { EmojiRows() }.edithForm(), size: CGSize(width: 900, height: 1000))
        #expect(try auditText(host).contains("No frequently used emoji yet"))
        let store = EmojiStore(
            catalog: .shared, insertionDelay: .zero, typeCharacter: { _ in true })
        defer { store.shutdown() }
        store.insert(character: "😀")
        try await Task.sleep(for: .milliseconds(500))
        host.needsLayout = true
        host.layoutSubtreeIfNeeded()
        #expect(EmojiCatalogSummary.frequent().contains("😀"))
        #expect(try !auditText(host).contains("No frequently used emoji yet"))
    }

    @Test func colorHistoryRefreshesWhileItsPageIsMounted() async throws {
        let keys = [AppStorageKeys.ColorPicker.enabled, "colorPickerHistory"]
        let previous = keys.map { SharedDefaults.store.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, previous) { SharedDefaults.store.set(value, forKey: key) }
        }
        SharedDefaults.store.set(true, forKey: AppStorageKeys.ColorPicker.enabled)
        ColorHistoryStore.clear()
        let host = try auditHost(
            Form { ColorPickerRows() }.edithForm(), size: CGSize(width: 900, height: 1000))
        #expect(try auditText(host).contains("No colors picked yet"))
        ColorHistoryStore.add(ColorSwatch(red: 1, green: 0, blue: 0, profile: .sRGB), limit: 10)
        IPC.post(IPC.Name.settingsChanged)
        try await Task.sleep(for: .milliseconds(500))
        host.needsLayout = true
        host.layoutSubtreeIfNeeded()
        #expect(try !auditText(host).contains("No colors picked yet"))
    }

    @Test func studioFilteredResultsExplainTheEmptyGrid() throws {
        let model = StudioModel(loadsState: false)
        model.files = [StudioFileItem(url: URL(fileURLWithPath: "/synthetic/sample.png"))]
        model.kindFilter = .audio
        let host = try auditHost(
            StudioFilesView(model: model), size: CGSize(width: 900, height: 500))
        #expect(try auditText(host).contains("No files match this filter"))
        #expect(try auditText(host).contains("Show all files"))
    }
}

private actor ClipboardRecentFixture {
    private var requests = 0

    func load() throws -> [ClipboardEntry] {
        requests += 1
        if requests == 2 { throw CocoaError(.fileReadUnknown) }
        guard requests == 1 else { return [] }
        return [
            ClipboardEntry(
                sha256: String(repeating: "a", count: 64), types: ["public.utf8-plain-text"],
                ext: "txt", sourceApp: "Sample Notes", sourceBundleID: "test.notes", size: 12,
                preview: "Sample text")
        ]
    }
}
