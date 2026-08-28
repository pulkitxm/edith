import AppKit
import EdithKit
import Foundation

@MainActor
@Observable
final class EmojiStore: FeatureModule {
    private(set) var catalog: EmojiCatalog
    private(set) var frequent: [Emoji] = []
    private(set) var revision = 0

    var skinTone: EmojiSkinTone {
        didSet {
            guard skinTone != oldValue else { return }
            SharedDefaults.store.set(skinTone.rawValue, forKey: AppStorageKeys.Emoji.skinTone)
            revision += 1
        }
    }

    private var ledger: EmojiUsageLedger
    private var settingsObserver: NSObjectProtocol?
    private var insertionTasks: [UUID: Task<Void, Never>] = [:]
    private var insertionCompletions: [UUID: @MainActor (Bool) -> Void] = [:]
    private var isShutDown = false
    private let insertionDelay: Duration
    private let typeCharacter: @MainActor (String) -> Bool

    required convenience init() {
        self.init(catalog: .shared, typeCharacter: { EmojiTypeSynth.type($0) })
    }

    init(
        catalog: EmojiCatalog, insertionDelay: Duration = .milliseconds(50),
        typeCharacter: @escaping @MainActor (String) -> Bool
    ) {
        self.catalog = catalog
        self.insertionDelay = insertionDelay
        self.typeCharacter = typeCharacter
        ledger = EmojiUsageLedger.load(from: SharedDefaults.store, key: AppStorageKeys.Emoji.usage)
        skinTone = EmojiSkinTone.stored(forKey: AppStorageKeys.Emoji.skinTone)
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
        record(character)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(character, forType: .string)
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
        ledger.save(to: SharedDefaults.store, key: AppStorageKeys.Emoji.usage)
    }

    private func refreshFrequent() {
        frequent = EmojiCatalogSummary.frequent(catalog: catalog, store: SharedDefaults.store)
            .compactMap { character in
                guard let entry = catalog.emoji(matching: character) else { return nil }
                return Emoji(
                    character: character, name: entry.name, groupIndex: entry.groupIndex,
                    unicodeVersion: entry.unicodeVersion, terms: entry.terms)
            }
        revision += 1
    }

    private func adoptSettings() {
        let tone = EmojiSkinTone.stored(forKey: AppStorageKeys.Emoji.skinTone)
        if tone != skinTone { skinTone = tone }
        ledger = EmojiUsageLedger.load(from: SharedDefaults.store, key: AppStorageKeys.Emoji.usage)
        refreshFrequent()
    }
}
