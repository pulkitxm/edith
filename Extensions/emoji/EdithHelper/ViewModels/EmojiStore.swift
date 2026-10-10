#if canImport(WorkerFixtureSupport)
import WorkerFixtureSupport
#endif
import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import Foundation

@MainActor
@Observable
final class EmojiStore: FeatureModule {
    private(set) var catalog: EmojiCatalog
    private(set) var frequent: [Emoji] = []
    private(set) var frequentIDs: Set<String> = []
    private(set) var revision = 0
    let search: @Sendable (String) async -> [Emoji]

    var skinTone: EmojiSkinTone {
        didSet {
            guard skinTone != oldValue else { return }
            defaults.set(skinTone.rawValue, forKey: AppStorageKeys.Emoji.skinTone)
            revision += 1
        }
    }

    private let defaults: UserDefaults
    private let writePasteboard: (String) -> Bool
    private var ledger: EmojiUsageLedger
    private var settingsObserver: NSObjectProtocol?
    private var insertionTasks: [UUID: Task<Void, Never>] = [:]
    private var insertionCompletions: [UUID: @MainActor (Bool) -> Void] = [:]
    private var isShutDown = false
    private let insertionDelay: Duration
    private let typeCharacter: @MainActor (String) -> Bool

    private(set) var fixtureOutput: EmojiFixtureOutput?

    convenience init(fixture: WorkerFixtureAdmission?) {
        guard let fixture else { self.init(); return }
        precondition(fixture.extensionID == "emoji")
        let output = EmojiFixtureOutput()
        self.init(
            writePasteboard: {
                output.copied.append($0)
                if output.copied.count > 128 {
                    output.copied.removeFirst(output.copied.count - 128)
                }
                return true
            }, catalog: .shared, insertionDelay: .zero,
            typeCharacter: {
                output.inserted.append($0)
                if output.inserted.count > 128 {
                    output.inserted.removeFirst(output.inserted.count - 128)
                }
                return true
            })
        fixtureOutput = output
    }

    required convenience init() {
        self.init(catalog: .shared, typeCharacter: { EmojiTypeSynth.type($0) })
    }

    init(
        defaults: UserDefaults = SharedDefaults.store,
        writePasteboard: @escaping (String) -> Bool = { character in
            NSPasteboard.general.clearContents()
            return NSPasteboard.general.setString(character, forType: .string)
        },
        catalog: EmojiCatalog, insertionDelay: Duration = .milliseconds(50),
        typeCharacter: @escaping @MainActor (String) -> Bool
    ) {
        self.defaults = defaults
        self.writePasteboard = writePasteboard
        self.catalog = catalog
        let searchService = EmojiSearchService(catalog.emoji)
        search = { await searchService.results(query: $0) }
        self.insertionDelay = insertionDelay
        self.typeCharacter = typeCharacter
        ledger = EmojiUsageLedger.load(from: defaults, key: AppStorageKeys.Emoji.usage)
        skinTone = EmojiSkinTone.stored(forKey: AppStorageKeys.Emoji.skinTone, store: defaults)
        refreshFrequent()
        settingsObserver = IPC.observe(IPC.Name.settingsChanged) { [weak self] in
            Task { @MainActor in self?.adoptSettings() }
        }
    }

    func shutdown() {
        guard !isShutDown else { return }
        isShutDown = true
        if let settingsObserver { IPC.stopObserving(settingsObserver) }
        settingsObserver = nil
        insertionTasks.values.forEach { $0.cancel() }
        insertionTasks.removeAll()
        let completions = insertionCompletions.values
        insertionCompletions.removeAll()
        completions.forEach { $0(false) }
    }

    func emoji(inGroup index: Int) -> [Emoji] {
        catalog.emoji(inGroup: index)
    }

    func character(for emoji: Emoji) -> String {
        emoji.character(tone: skinTone)
    }

    func insertAndWait(character: String) async throws -> Bool {
        guard !isShutDown, catalog.emoji(matching: character) != nil else { return false }
        try await Task.sleep(for: insertionDelay)
        try Task.checkCancellation()
        guard !isShutDown else { return false }
        let inserted = typeCharacter(character)
        if inserted { record(character) }
        return inserted
    }

    func insert(_ emoji: Emoji, tone: EmojiSkinTone? = nil) {
        insert(character: emoji.character(tone: tone ?? skinTone))
    }

    func insert(
        character: String, completion: @escaping @MainActor (Bool) -> Void = { _ in }
    ) {
        guard !isShutDown, catalog.emoji(matching: character) != nil else {
            completion(false)
            return
        }
        if insertionDelay == .zero {
            let inserted = typeCharacter(character)
            if inserted { record(character) }
            completion(inserted)
            return
        }
        let id = UUID()
        insertionCompletions[id] = completion
        insertionTasks[id] = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: self?.insertionDelay ?? .zero)
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            let inserted = self.typeCharacter(character)
            if inserted { self.record(character) }
            self.finishInsertion(id: id, inserted: inserted)
        }
    }

    func copy(_ emoji: Emoji, tone: EmojiSkinTone? = nil) {
        let character = emoji.character(tone: tone ?? skinTone)
        guard writePasteboard(character) else { NSSound.beep(); return }
        record(character)
    }

    func forget(_ character: String) {
        ledger.forget(character)
        persistLedger()
        refreshFrequent()
    }

    func clearFrequent() {
        ledger.clear()
        persistLedger()
        refreshFrequent()
    }

    private func record(_ character: String) {
        ledger.record(character, at: Date())
        persistLedger()
        refreshFrequent()
    }

    private func finishInsertion(id: UUID, inserted: Bool) {
        insertionTasks[id] = nil
        let completion = insertionCompletions.removeValue(forKey: id)
        completion?(inserted)
    }

    private func persistLedger() {
        ledger.save(to: defaults, key: AppStorageKeys.Emoji.usage)
        IPC.post(IPC.Name.emojiUsageChanged)
    }

    private func refreshFrequent() {
        var refreshed: [Emoji] = []
        for character in EmojiCatalogSummary.frequent(
            catalog: catalog, store: defaults)
        {
            if let entry = catalog.emoji(matching: character) {
                refreshed.append(
                    Emoji(
                        character: character, name: entry.name, groupIndex: entry.groupIndex,
                        unicodeVersion: entry.unicodeVersion, terms: entry.terms))
            }
        }
        frequent = refreshed
        var refreshedIDs: Set<String> = []
        for emoji in refreshed { refreshedIDs.insert(emoji.id) }
        frequentIDs = refreshedIDs
        revision += 1
    }

    func adoptSettings() {
        let tone = EmojiSkinTone.stored(forKey: AppStorageKeys.Emoji.skinTone, store: defaults)
        if tone != skinTone { skinTone = tone }
        ledger = EmojiUsageLedger.load(from: defaults, key: AppStorageKeys.Emoji.usage)
        refreshFrequent()
    }
}

@MainActor final class EmojiFixtureOutput {
    var copied: [String] = []
    var inserted: [String] = []
}
