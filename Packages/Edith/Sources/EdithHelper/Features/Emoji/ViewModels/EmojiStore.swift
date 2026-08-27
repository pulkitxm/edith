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
    private let typeCharacter: @MainActor (String) -> Void

    required convenience init() {
        self.init(catalog: .shared, typeCharacter: { EmojiTypeSynth.type($0) })
    }

    init(catalog: EmojiCatalog, typeCharacter: @escaping @MainActor (String) -> Void) {
        self.catalog = catalog
        self.typeCharacter = typeCharacter
        ledger = EmojiUsageLedger.load(from: SharedDefaults.store, key: AppStorageKeys.Emoji.usage)
        skinTone = EmojiSkinTone.stored(forKey: AppStorageKeys.Emoji.skinTone)
        refreshFrequent()
        settingsObserver = IPC.observe(IPC.Name.settingsChanged) { [weak self] in
            Task { @MainActor in self?.adoptSettings() }
        }
    }

    func shutdown() {
        if let settingsObserver { IPC.stopObserving(settingsObserver) }
        settingsObserver = nil
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

    func insert(character: String) {
        guard !character.isEmpty else { return }
        record(character)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [typeCharacter] in
            typeCharacter(character)
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
