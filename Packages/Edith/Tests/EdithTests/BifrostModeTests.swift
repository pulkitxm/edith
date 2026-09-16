import Foundation
import Testing

@testable import EdithKit

@Suite struct BifrostModeTests {
    private let now = Date(timeIntervalSince1970: 1_789_500_000)

    private func entry(
        id: String, preview: String?, ext: String = "txt", app: String? = "Notes",
        pinned: Bool = false, ageSeconds: TimeInterval = 0,
        types: [String] = ["public.utf8-plain-text"]
    ) -> ClipboardEntry {
        ClipboardEntry(
            id: id, sha256: id, types: types, ext: ext, sourceApp: app, sourceBundleID: nil,
            createdAt: now.addingTimeInterval(-ageSeconds),
            lastCopiedAt: now.addingTimeInterval(-ageSeconds), size: 120, preview: preview,
            pinned: pinned)
    }

    @Test func everyModeNamesItselfAndItsAction() {
        for mode in BifrostMode.allCases {
            #expect(!mode.title.isEmpty)
            #expect(!mode.placeholder.isEmpty)
            #expect(!mode.primaryAction.isEmpty)
        }
        #expect(BifrostMode.clipboard.primaryAction == "Paste")
        #expect(!BifrostMode.launcher.showsDetail)
        #expect(BifrostMode.files.showsDetail)
    }

    @Test func clipboardEntriesAreClassifiedByWhatTheyHold() {
        #expect(BifrostClipboardFeed.kind(of: entry(id: "a", preview: "hello")) == "text")
        #expect(
            BifrostClipboardFeed.kind(of: entry(id: "b", preview: "https://example.com"))
                == "link")
        #expect(BifrostClipboardFeed.kind(of: entry(id: "c", preview: nil, ext: "png")) == "image")
        #expect(
            BifrostClipboardFeed.kind(
                of: entry(id: "d", preview: "x", types: ["public.file-url"])) == "file")
    }

    @Test func pinnedEntriesLeadAndTheRestAreNewestFirst() {
        let ordered = BifrostClipboardFeed.ordered([
            entry(id: "old", preview: "old", ageSeconds: 600),
            entry(id: "new", preview: "new"),
            entry(id: "pinned", preview: "pinned", pinned: true, ageSeconds: 9_000),
        ])

        #expect(ordered.map(\.id) == ["pinned", "new", "old"])
    }

    @Test func aScopeNarrowsTheHistoryAndAQueryFiltersIt() {
        let entries = [
            entry(id: "a", preview: "hello world"),
            entry(id: "b", preview: "https://example.com"),
            entry(id: "c", preview: nil, ext: "png"),
        ]

        let all = BifrostClipboardFeed.results(
            entries: entries, query: "", scope: "all", now: now)
        let links = BifrostClipboardFeed.results(
            entries: entries, query: "", scope: "link", now: now)
        let searched = BifrostClipboardFeed.results(
            entries: entries, query: "hello", scope: "all", now: now)

        #expect(all.count == 3)
        #expect(links.map(\.title) == ["https://example.com"])
        #expect(searched.map(\.title) == ["hello world"])
    }

    @Test func aClipboardRowCarriesItsInformation() throws {
        let results = BifrostClipboardFeed.results(
            entries: [entry(id: "a", preview: "hello")], query: "", scope: "all", now: now)
        let detail = try #require(results.first?.detail)

        #expect(detail.title == "Information")
        #expect(detail.rows.map(\.label) == ["Source", "Content type", "Size", "Copied"])
        #expect(detail.rows.first?.value == "Notes")
    }

    @Test func historyIsGroupedByTheDayItWasCopied() {
        let yesterday = now.addingTimeInterval(-86_400)
        #expect(BifrostClipboardFeed.group(for: now, now: now) == "Today")
        #expect(BifrostClipboardFeed.group(for: yesterday, now: now) == "Yesterday")
        #expect(
            BifrostClipboardFeed.group(for: now.addingTimeInterval(-86_400 * 10), now: now)
                != "Today")

        let results = BifrostClipboardFeed.results(
            entries: [
                entry(id: "a", preview: "today"),
                entry(id: "b", preview: "old", ageSeconds: 86_400 * 3),
            ], query: "", scope: "all", now: now)
        let sections = BifrostSectionBuilder.sections(from: results, query: "")

        #expect(sections.count == 2)
        #expect(sections.first?.title == "Today")
    }

    @Test func aTextEntryReportsItsOwnLengthWhenTheBlobIsEmpty() {
        let empty = ClipboardEntry(
            id: "e", sha256: "e", types: [], ext: "txt", sourceApp: nil, sourceBundleID: nil,
            createdAt: now, lastCopiedAt: now, size: 0, preview: "hello", pinned: false)
        #expect(BifrostClipboardFeed.bytes(of: empty) == 5)
        #expect(BifrostClipboardFeed.bytes(of: entry(id: "f", preview: "x")) == 120)
    }

    @Test func filesAreLabelledRecentUntilYouSearch() {
        let file = BifrostFile(
            path: "/Users/x/a.txt", name: "a.txt", kind: "TXT file", size: 1, created: nil,
            modified: now)
        #expect(BifrostFileSearch.results(files: [file], now: now).first?.group == "Recent Files")
        #expect(
            BifrostFileSearch.results(files: [file], now: now, query: "a").first?.group
                == "Results")
    }

    @Test func fileSearchAsksSpotlightTheRightQuestion() {
        let named = BifrostFileSearch.arguments(query: "report", scopePath: "/Users/x")
        let recent = BifrostFileSearch.arguments(query: "  ", scopePath: nil)

        #expect(named == ["-onlyin", "/Users/x", "-name", "report"])
        #expect(recent == ["kMDItemLastUsedDate >= $time.today(-7)"])
    }

    @Test func onlyAbsolutePathsSurviveTheOutput() {
        let output = "/Users/x/a.txt\nnot a path\n/Users/x/b.png\n"
        #expect(BifrostFileSearch.paths(from: output) == ["/Users/x/a.txt", "/Users/x/b.png"])
        #expect(BifrostFileSearch.paths(from: "", limit: 5).isEmpty)
    }

    @Test func theOutputIsCappedSoATypoCannotFloodTheBar() {
        let output = (0..<200).map { "/Users/x/\($0).txt" }.joined(separator: "\n")
        #expect(BifrostFileSearch.paths(from: output).count == BifrostFileSearch.limit)
    }

    @Test func filesAreDescribedAndNewestFirst() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("bifrost-files-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let older = directory.appendingPathComponent("older.txt")
        let newer = directory.appendingPathComponent("newer.png")
        try Data("older".utf8).write(to: older)
        try Data("newer".utf8).write(to: newer)
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-9_000)], ofItemAtPath: older.path)
        try FileManager.default.setAttributes(
            [.modificationDate: now], ofItemAtPath: newer.path)

        let described = BifrostFileSearch.describe(paths: [older.path, newer.path])

        #expect(described.map(\.name) == ["newer.png", "older.txt"])
        #expect(described.first?.kind == "PNG image")
        #expect(described.last?.size == 5)
    }

    @Test func aFileRowCarriesItsMetadataAndOpensThePath() throws {
        let file = BifrostFile(
            path: "/Users/x/Pictures/shot.png", name: "shot.png", kind: "PNG image",
            size: 163_000, created: now, modified: now)
        let result = try #require(BifrostFileSearch.results(files: [file], now: now).first)
        let detail = try #require(result.detail)

        #expect(result.action == .launch(path: file.path))
        #expect(detail.title == "Metadata")
        #expect(
            detail.rows.map(\.label) == ["Name", "Where", "Type", "Size", "Created", "Modified"])
        #expect(detail.imagePath == file.path)
    }

    @Test func scopesExistForEveryModeThatShowsDetail() {
        for mode in BifrostMode.allCases where mode.showsDetail {
            #expect(!BifrostScopeCatalog.scopes(for: mode).isEmpty)
        }
        #expect(BifrostScopeCatalog.scopes(for: .launcher).isEmpty)
        #expect(BifrostScopeCatalog.files(home: "/Users/sam").first?.title == "User (sam)")
    }

    @Test func theClipboardAndFileCommandsOpenTheirModes() {
        #expect(BifrostCommandCatalog.command(id: "clipboard.open")?.mode == .clipboard)
        #expect(BifrostCommandCatalog.command(id: "files.search")?.mode == .files)
        #expect(BifrostCommandCatalog.command(id: "panel.open")?.mode == nil)
    }
}
