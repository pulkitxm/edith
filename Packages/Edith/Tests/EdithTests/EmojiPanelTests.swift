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

    @Test func initialRenderingStateIsBoundedAcrossTheFullCatalog() {
        let model = EmojiPanelModel(catalog: .shared, frequent: [])
        let completeCount = model.sections.reduce(0) { $0 + $1.emoji.count }
        let initialBound =
            EmojiPanelModel.pageSize
            + max(model.sections.count - 1, 0) * EmojiPanelView.columns

        #expect(completeCount == EmojiCatalog.shared.emoji.count)
        #expect(model.renderedCellCount <= initialBound)
        #expect(model.renderedCellCount < completeCount)
    }

    @Test func pageExpansionKeepsSelectionAndStableCellIDs() {
        let model = EmojiPanelModel(catalog: .shared, frequent: [])
        let section = model.sections[0]
        let selectedID = model.selectedID
        let originalIDs = Set(model.rows(for: model.renderedSections[0]).flatMap(\.cells).map(\.id))

        model.extend(sectionID: section.id)

        let expanded = model.renderedSections[0]
        let expandedIDs = Set(model.rows(for: expanded).flatMap(\.cells).map(\.id))
        #expect(model.selectedID == selectedID)
        #expect(originalIDs.isSubset(of: expandedIDs))
        #expect(expanded.emoji.count > originalIDs.count)
    }

    @Test func keyboardSelectionRendersItsTargetBeforeScrolling() {
        let model = EmojiPanelModel(catalog: .shared, frequent: [])
        let selectedID = model.moveSelection(delta: EmojiPanelModel.pageSize + 10)

        #expect(selectedID != nil)
        #expect(
            model.renderedSections
                .flatMap { model.rows(for: $0) }
                .flatMap(\.cells)
                .contains { $0.id == selectedID })
    }

    @Test func categoryJumpKeepsEveryCategoryReachableFromTheBoundedState() throws {
        let model = EmojiPanelModel(catalog: .shared, frequent: [])
        let target = try #require(model.sections.last)

        #expect(model.revealSection(target.id) == target.id)
        #expect(
            model.renderedSections.first(where: { $0.id == target.id })?.emoji.first
                == target.emoji.first)
    }

    @Test func structuredPositionsKeepSeparatorBearingIDsIntact() {
        let unusual = EmojiCatalog(
            groups: [
                EmojiGroup(
                    id: "group:with|separators", name: "Unusual", symbolName: "number")
            ],
            emoji: [
                Emoji(
                    character: "value:with|separators", name: "separator fixture", groupIndex: 0,
                    unicodeVersion: 1)
            ])
        let model = EmojiPanelModel(catalog: unusual, frequent: [])
        let expected = EmojiPanelCell.ID(
            sectionID: "group:with|separators", emojiID: "value:with|separators")

        #expect(model.selectedID == expected)
        #expect(model.sectionOffset(for: "group:with|separators") == 0)
        #expect(model.revealSection("group:with|separators") == "group:with|separators")
        #expect(model.moveSelection(delta: 1) == expected)
    }

    @Test func staleSearchCannotReplaceTheNewestQueryOrPublishAfterCancellation() async {
        let fixture = EmojiPanelSearchFixture()
        let model = EmojiPanelModel(
            catalog: catalog, frequent: [], search: { await fixture.search($0) })

        model.setQuery("smile")
        await fixture.waitUntilStarted(1)
        model.setQuery("rocket")
        await fixture.waitUntilStarted(2)
        await fixture.release(1, result: [catalog.emoji[2]])
        for _ in 0..<100 where model.isSearching { await Task.yield() }

        #expect(model.query == "rocket")
        #expect(model.sections.flatMap(\.emoji).map(\.character) == ["🚀"])

        await fixture.release(0, result: [catalog.emoji[0], catalog.emoji[1]])
        await Task.yield()
        #expect(model.sections.flatMap(\.emoji).map(\.character) == ["🚀"])

        model.setQuery("love")
        await fixture.waitUntilStarted(3)
        model.cancelSearch()
        await fixture.release(2, result: [catalog.emoji[1]])
        await Task.yield()
        #expect(model.sections.flatMap(\.emoji).map(\.character) == ["🚀"])
        #expect(!model.isSearching)
    }
}

private actor EmojiPanelSearchFixture {
    private var started = 0
    private var startWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var searchWaiters: [Int: CheckedContinuation<[Emoji], Never>] = [:]

    func search(_ query: String) async -> [Emoji] {
        let index = started
        started += 1
        let ready = startWaiters.filter { started >= $0.0 }
        startWaiters.removeAll { started >= $0.0 }
        ready.forEach { $0.1.resume() }
        return await withCheckedContinuation { searchWaiters[index] = $0 }
    }

    func waitUntilStarted(_ count: Int) async {
        guard started < count else { return }
        await withCheckedContinuation { startWaiters.append((count, $0)) }
    }

    func release(_ index: Int, result: [Emoji]) {
        searchWaiters.removeValue(forKey: index)?.resume(returning: result)
    }
}

@Suite @MainActor struct EmojiStoreTests {
    private func makeStore() -> (EmojiStore, Box) {
        let box = Box()
        let store = EmojiStore(
            catalog: catalog, insertionDelay: .zero,
            typeCharacter: {
                box.typed.append($0)
                return true
            })
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
            catalog: EmojiCatalog(groups: catalog.groups, emoji: [toned]),
            insertionDelay: .zero, typeCharacter: { _ in true })
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
        let (store, _) = makeStore()
        for _ in 0..<3 { store.insert(catalog.emoji[0]) }
        store.insert(catalog.emoji[2])
        SharedDefaults.store.set(-4, forKey: AppStorageKeys.Emoji.frequentCount)
        #expect(EmojiCatalogSummary.frequent(catalog: catalog).isEmpty)
        SharedDefaults.store.set(999, forKey: AppStorageKeys.Emoji.frequentCount)
        #expect(EmojiCatalogSummary.frequent(catalog: catalog) == ["😀", "🚀"])
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
        let (store, box) = makeStore()
        store.insert(character: "not emoji")
        #expect(store.frequent.isEmpty)
        #expect(box.typed.isEmpty)
    }

    @Test func failedTypingDoesNotRecordUsage() {
        clearDefaults()
        defer { clearDefaults() }
        let store = EmojiStore(
            catalog: catalog, insertionDelay: .zero, typeCharacter: { _ in false })
        var inserted: Bool?
        store.insert(character: "🚀") { inserted = $0 }
        #expect(inserted == false)
        #expect(store.frequent.isEmpty)
    }

    @Test func shutdownCancelsPendingTypingAndCompletesTheRequest() async {
        clearDefaults()
        defer { clearDefaults() }
        let box = Box()
        let store = EmojiStore(
            catalog: catalog, insertionDelay: .milliseconds(100),
            typeCharacter: {
                box.typed.append($0)
                return true
            })
        var inserted: Bool?
        store.insert(character: "🚀") { inserted = $0 }
        store.shutdown()
        try? await Task.sleep(for: .milliseconds(150))
        #expect(inserted == false)
        #expect(box.typed.isEmpty)
        #expect(store.frequent.isEmpty)
    }
}
