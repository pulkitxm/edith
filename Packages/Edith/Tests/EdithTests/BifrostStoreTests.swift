import AppKit
import Foundation
import Testing

@testable import EdithHelper
@testable import EdithKit

@Suite @MainActor struct BifrostStoreTests {
    nonisolated private static let applications = [
        BifrostApplication(name: "Safari", path: "/Applications/Safari.app"),
        BifrostApplication(name: "Notes", path: "/System/Applications/Notes.app"),
    ]

    private final class Recorder: @unchecked Sendable {
        var opened: [String] = []
        var copied: [String] = []
        var refused: Set<String> = []
    }

    private func makeWorld() -> (UserDefaults, BifrostIndexStore, String, URL) {
        let suiteName = "BifrostStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("bifrost-store-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let indexStore = BifrostIndexStore(
            location: directory.appendingPathComponent("index.json"))
        return (defaults, indexStore, suiteName, directory)
    }

    private func makeStore(
        defaults: UserDefaults, indexStore: BifrostIndexStore, recorder: Recorder,
        scan: @escaping @Sendable () -> [BifrostApplication] = { applications }
    ) -> BifrostStore {
        BifrostStore(
            store: defaults, indexStore: indexStore, scan: scan,
            open: { path in
                guard !recorder.refused.contains(path) else { return false }
                recorder.opened.append(path)
                return true
            },
            copy: { recorder.copied.append($0) })
    }

    @Test func aCachedIndexIsAdoptedWithoutScanning() async {
        let (defaults, indexStore, suiteName, directory) = makeWorld()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        indexStore.save(
            BifrostIndex(generatedAt: Date(), applications: Self.applications))
        let recorder = Recorder()

        let store = makeStore(
            defaults: defaults, indexStore: indexStore, recorder: recorder,
            scan: {
                Issue.record("a cached index should not be rescanned"); return []
            })
        defer { store.shutdown() }

        #expect(store.applications.map(\.name) == ["Safari", "Notes"])
        #expect(!store.isIndexing)
    }

    @Test func anEmptyCacheIsBuiltOnFirstUse() async throws {
        let (defaults, indexStore, suiteName, directory) = makeWorld()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        let recorder = Recorder()

        let store = makeStore(defaults: defaults, indexStore: indexStore, recorder: recorder)
        defer { store.shutdown() }
        try await waitUntil { !store.applications.isEmpty }

        #expect(store.applications.map(\.name) == ["Safari", "Notes"])
        #expect(store.indexedAt != nil)
        #expect(defaults.object(forKey: AppStorageKeys.Bifrost.indexedAt) as? Double != nil)
        #expect(indexStore.load()?.applications.count == 2)
    }

    @Test func openingAnApplicationRecordsItAndRankingFollows() async throws {
        let (defaults, indexStore, suiteName, directory) = makeWorld()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        indexStore.save(BifrostIndex(generatedAt: Date(), applications: Self.applications))
        let recorder = Recorder()
        let store = makeStore(defaults: defaults, indexStore: indexStore, recorder: recorder)
        defer { store.shutdown() }

        let notes = try #require(store.results(for: "notes").first)
        #expect(store.run(notes))
        #expect(recorder.opened == ["/System/Applications/Notes.app"])
        #expect(store.results(for: "").map(\.title) == ["Notes"])
    }

    @Test func anApplicationThatWillNotOpenIsNotRecorded() throws {
        let (defaults, indexStore, suiteName, directory) = makeWorld()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        indexStore.save(BifrostIndex(generatedAt: Date(), applications: Self.applications))
        let recorder = Recorder()
        recorder.refused = ["/Applications/Safari.app"]
        let store = makeStore(defaults: defaults, indexStore: indexStore, recorder: recorder)
        defer { store.shutdown() }

        let safari = try #require(store.results(for: "safari").first)
        #expect(!store.run(safari))
        #expect(recorder.opened.isEmpty)
        #expect(store.results(for: "").isEmpty)
    }

    @Test func anAnswerIsCopiedRatherThanOpened() throws {
        let (defaults, indexStore, suiteName, directory) = makeWorld()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        indexStore.save(BifrostIndex(generatedAt: Date(), applications: Self.applications))
        let recorder = Recorder()
        let store = makeStore(defaults: defaults, indexStore: indexStore, recorder: recorder)
        defer { store.shutdown() }

        let answer = try #require(store.results(for: "2+2").first)
        #expect(answer.kind == .calculation)
        #expect(store.run(answer))
        #expect(recorder.copied == ["4"])
        #expect(recorder.opened.isEmpty)
    }

    @Test func anApplicationCanBeCopiedInsteadOfOpened() throws {
        let (defaults, indexStore, suiteName, directory) = makeWorld()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        indexStore.save(BifrostIndex(generatedAt: Date(), applications: Self.applications))
        let recorder = Recorder()
        let store = makeStore(defaults: defaults, indexStore: indexStore, recorder: recorder)
        defer { store.shutdown() }

        let safari = try #require(store.results(for: "safari").first)
        store.copy(safari)

        #expect(recorder.copied == ["/Applications/Safari.app"])
        #expect(recorder.opened.isEmpty)
        #expect(store.results(for: "").isEmpty)
    }

    @Test func theResultLimitIsClampedToWhatTheBarCanShow() {
        let (defaults, indexStore, suiteName, directory) = makeWorld()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        indexStore.save(BifrostIndex(generatedAt: Date(), applications: Self.applications))
        let recorder = Recorder()
        let store = makeStore(defaults: defaults, indexStore: indexStore, recorder: recorder)
        defer { store.shutdown() }

        #expect(store.resultLimit == BifrostQuery.defaultLimit)
        defaults.set(999, forKey: AppStorageKeys.Bifrost.resultLimit)
        #expect(store.resultLimit == BifrostQuery.maximumResultLimit)
        defaults.set(0, forKey: AppStorageKeys.Bifrost.resultLimit)
        #expect(store.resultLimit == BifrostQuery.minimumResultLimit)
    }

    @Test func shutdownStopsFurtherIndexing() async throws {
        let (defaults, indexStore, suiteName, directory) = makeWorld()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        indexStore.save(BifrostIndex(generatedAt: Date(), applications: Self.applications))
        let recorder = Recorder()
        let store = makeStore(
            defaults: defaults, indexStore: indexStore, recorder: recorder,
            scan: {
                Issue.record("a shut down store should not scan"); return []
            })

        store.shutdown()
        store.reindex()
        try await Task.sleep(for: .milliseconds(20))

        #expect(!store.isIndexing)
    }

    private func waitUntil(
        _ condition: @MainActor () -> Bool, attempts: Int = 200
    ) async throws {
        for _ in 0..<attempts {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("the condition never became true")
    }
}

@Suite @MainActor struct BifrostPanelModelTests {
    private func results(_ titles: [String]) -> [BifrostResult] {
        var built: [BifrostResult] = []
        for title in titles {
            built.append(
                BifrostResult(
                    id: "app:/\(title).app", kind: .application, title: title,
                    subtitle: "/Applications", symbolName: "app.dashed",
                    action: .launch(path: "/\(title).app"), score: 1))
        }
        return built
    }

    @Test func theFirstResultIsSelectedAndArrowsWalkTheList() {
        let model = BifrostPanelModel(resolve: { _ in self.results(["One", "Two", "Three"]) })

        #expect(model.selected?.title == "One")
        model.moveSelection(delta: 1)
        #expect(model.selected?.title == "Two")
        model.moveSelection(delta: 1)
        model.moveSelection(delta: 1)
        #expect(model.selected?.title == "Three")
        model.moveSelection(delta: -1)
        #expect(model.selected?.title == "Two")
        model.moveSelection(delta: -5)
        #expect(model.selected?.title == "One")
    }

    @Test func typingReRanksAndReselectsTheTop() {
        let model = BifrostPanelModel(resolve: { query in
            query.isEmpty ? self.results(["One", "Two"]) : self.results(["Match"])
        })
        model.moveSelection(delta: 1)

        model.setQuery("m")

        #expect(model.query == "m")
        #expect(model.results.map(\.title) == ["Match"])
        #expect(model.selected?.title == "Match")
    }

    @Test func refreshingKeepsTheSelectionWhenItSurvives() {
        let model = BifrostPanelModel(resolve: { _ in self.results(["One", "Two"]) })
        model.moveSelection(delta: 1)

        model.refresh()

        #expect(model.selected?.title == "Two")
    }

    @Test func anEmptyResultSetSelectsNothing() {
        let model = BifrostPanelModel(resolve: { _ in [] })

        #expect(model.selected == nil)
        model.moveSelection(delta: 1)
        #expect(model.selected == nil)
    }

    @Test func hoveringSelectsOnlyRowsThatExist() {
        let model = BifrostPanelModel(resolve: { _ in self.results(["One", "Two"]) })

        model.select("app:/Two.app")
        #expect(model.selected?.title == "Two")
        model.select("app:/nowhere.app")
        #expect(model.selected?.title == "Two")
    }

    @Test func resetClearsTheQueryOrSeedsIt() {
        let model = BifrostPanelModel(resolve: { query in
            query.isEmpty ? self.results(["One"]) : self.results(["Seeded"])
        })

        model.reset(query: "seed")
        #expect(model.query == "seed")
        #expect(model.results.map(\.title) == ["Seeded"])

        model.reset()
        #expect(model.query.isEmpty)
        #expect(model.results.map(\.title) == ["One"])
    }
}

@Suite @MainActor struct BifrostEditingActionTests {
    @Test func theFieldKeepsEveryStandardEditingShortcut() {
        #expect(BifrostEditingAction.selector(for: "a", shifted: false) != nil)
        #expect(BifrostEditingAction.selector(for: "c", shifted: false) != nil)
        #expect(BifrostEditingAction.selector(for: "v", shifted: false) != nil)
        #expect(BifrostEditingAction.selector(for: "x", shifted: false) != nil)
    }

    @Test func undoAndRedoDifferByShift() {
        let undo = BifrostEditingAction.selector(for: "z", shifted: false)
        let redo = BifrostEditingAction.selector(for: "z", shifted: true)
        #expect(undo != redo)
        #expect(undo == Selector(("undo:")))
        #expect(redo == Selector(("redo:")))
    }

    @Test func anythingElseIsLeftToTheResponderChain() {
        #expect(BifrostEditingAction.selector(for: "q", shifted: false) == nil)
        #expect(BifrostEditingAction.selector(for: "w", shifted: true) == nil)
    }
}
