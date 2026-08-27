import AppKit
import Foundation
import Testing

@testable import EdithHelper
@testable import EdithKit

private let catalog = EmojiCatalog(
    groups: [
        EmojiGroup(id: "smileys-emotion", name: "Smileys", symbolName: "face.smiling"),
        EmojiGroup(id: "travel-places", name: "Travel", symbolName: "airplane"),
    ],
    emoji: [
        Emoji(character: "😀", name: "grinning face", groupIndex: 0, unicodeVersion: 1),
        Emoji(
            character: "😍", name: "smiling face with heart-eyes", groupIndex: 0,
            unicodeVersion: 0.6, terms: ["love"]),
        Emoji(
            character: "🚀", name: "rocket", groupIndex: 1, unicodeVersion: 0.6,
            terms: ["launch"]),
    ])

private let frequent = [
    Emoji(character: "🚀", name: "rocket", groupIndex: 1, unicodeVersion: 0.6)
]

@Suite @MainActor struct EmojiPanelSectionTests {
    @Test func emptyQueryListsFrequentThenEveryCatalogGroup() {
        let sections = EmojiPanelView.sections(catalog: catalog, frequent: frequent, query: "")
        #expect(sections.map(\.id) == ["frequent", "smileys-emotion", "travel-places"])
        #expect(sections[0].title == "Frequently used")
        #expect(sections[0].symbolName == "clock")
        #expect(sections[1].emoji.map(\.character) == ["😀", "😍"])
        #expect(sections[2].emoji.map(\.character) == ["🚀"])
    }

    @Test func frequentSectionIsOmittedWhenThereIsNoHistory() {
        let sections = EmojiPanelView.sections(catalog: catalog, frequent: [], query: "")
        #expect(sections.map(\.id) == ["smileys-emotion", "travel-places"])
    }

    @Test func searchCollapsesEverythingIntoOneRankedSection() {
        let sections = EmojiPanelView.sections(
            catalog: catalog, frequent: frequent, query: "rocket")
        #expect(sections.count == 1)
        #expect(sections[0].id == "results")
        #expect(sections[0].emoji.map(\.character) == ["🚀"])
    }

    @Test func searchWithoutMatchesProducesNoSections() {
        #expect(
            EmojiPanelView.sections(catalog: catalog, frequent: frequent, query: "aardvark")
                .isEmpty)
    }

    @Test func selectionMovesByOneAndByARowWithoutLeavingTheGrid() {
        #expect(EmojiPanelView.nextSelection(from: 0, delta: 1, count: 20) == 1)
        #expect(EmojiPanelView.nextSelection(from: 0, delta: -1, count: 20) == 0)
        #expect(EmojiPanelView.nextSelection(from: 19, delta: 1, count: 20) == 19)
        #expect(
            EmojiPanelView.nextSelection(from: 0, delta: EmojiPanelView.columns, count: 20)
                == EmojiPanelView.columns)
        #expect(
            EmojiPanelView.nextSelection(from: 3, delta: -EmojiPanelView.columns, count: 20) == 0)
        #expect(EmojiPanelView.nextSelection(from: 0, delta: 1, count: 0) == 0)
    }

    @Test func gridFitsItsColumnsInsideThePanelWidth() {
        let cells = CGFloat(EmojiPanelView.columns) * EmojiPanelView.cellSize
        let gaps = CGFloat(EmojiPanelView.columns - 1) * EmojiPanelView.cellSpacing
        #expect(cells + gaps + 20 <= EmojiPanel.width)
    }
}

@Suite @MainActor struct EmojiStoreTests {
    private func makeStore() -> (EmojiStore, Box) {
        let box = Box()
        let store = EmojiStore(catalog: catalog, typeCharacter: { box.typed.append($0) })
        return (store, box)
    }

    private final class Box {
        var typed: [String] = []
    }

    private func clearDefaults() {
        SharedDefaults.store.removeObject(forKey: AppStorageKeys.Emoji.usage)
        SharedDefaults.store.removeObject(forKey: AppStorageKeys.Emoji.skinTone)
        SharedDefaults.store.removeObject(forKey: AppStorageKeys.Emoji.frequentCount)
    }

    @Test func insertingRecordsUsageAndPromotesTheEmojiToFrequent() {
        clearDefaults()
        defer { clearDefaults() }
        let (store, _) = makeStore()
        #expect(store.frequent.isEmpty)
        store.insert(catalog.emoji[2])
        #expect(store.frequent.map(\.character) == ["🚀"])
        store.insert(catalog.emoji[0])
        store.insert(catalog.emoji[0])
        #expect(store.frequent.map(\.character) == ["😀", "🚀"])
    }

    @Test func skinToneAppliesToTonedEmojiAndPersists() {
        clearDefaults()
        defer { clearDefaults() }
        let toned = Emoji(
            character: "👍", name: "thumbs up", groupIndex: 0, unicodeVersion: 0.6,
            toneVariants: ["👍🏻", "👍🏼", "👍🏽", "👍🏾", "👍🏿"])
        let store = EmojiStore(
            catalog: EmojiCatalog(groups: catalog.groups, emoji: [toned]), typeCharacter: { _ in })
        #expect(store.character(for: toned) == "👍")
        store.skinTone = .medium
        #expect(store.character(for: toned) == "👍🏽")
        #expect(
            SharedDefaults.store.object(forKey: AppStorageKeys.Emoji.skinTone) as? Int
                == EmojiSkinTone.medium.rawValue)
        #expect(EmojiSkinTone.stored(forKey: AppStorageKeys.Emoji.skinTone) == .medium)
    }

    @Test func frequentListHonoursTheConfiguredCountAndForgetting() {
        clearDefaults()
        defer { clearDefaults() }
        SharedDefaults.store.set(1, forKey: AppStorageKeys.Emoji.frequentCount)
        let (store, _) = makeStore()
        store.insert(catalog.emoji[0])
        store.insert(catalog.emoji[0])
        store.insert(catalog.emoji[2])
        #expect(store.frequent.map(\.character) == ["😀"])
        store.forget("😀")
        #expect(store.frequent.map(\.character) == ["🚀"])
        store.clearFrequent()
        #expect(store.frequent.isEmpty)
    }

    @Test func frequentCountIsClampedToTheSupportedRange() {
        clearDefaults()
        defer { clearDefaults() }
        #expect(EmojiStore.frequentCount == EmojiStore.defaultFrequentCount)
        SharedDefaults.store.set(-4, forKey: AppStorageKeys.Emoji.frequentCount)
        #expect(EmojiStore.frequentCount == 0)
        SharedDefaults.store.set(999, forKey: AppStorageKeys.Emoji.frequentCount)
        #expect(EmojiStore.frequentCount == EmojiStore.maxFrequentCount)
    }

    @Test func copyingPutsTheTonedCharacterOnThePasteboardAndCountsAsUse() {
        clearDefaults()
        defer { clearDefaults() }
        let (store, box) = makeStore()
        store.copy(catalog.emoji[2])
        #expect(NSPasteboard.general.string(forType: .string) == "🚀")
        #expect(box.typed.isEmpty)
        #expect(store.frequent.map(\.character) == ["🚀"])
    }

    @Test func insertingAnUnknownCharacterIsIgnored() {
        clearDefaults()
        defer { clearDefaults() }
        let (store, _) = makeStore()
        store.insert(character: "")
        #expect(store.frequent.isEmpty)
    }
}
