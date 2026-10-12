import EdithExtensionSupport
import Foundation

enum EmojiSurface {
    #if EDITH_FUNCTIONAL_FIXTURE
    struct Selection: Decodable {
        let action: String
        let value: String
        let phase: String

        static func decode(_ payload: Data, phase: String) throws -> Selection {
            guard let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
                Set(object.keys) == ["action", "value", "phase"]
            else { throw ExtensionPeerError.invalidRequest }
            let selection = try JSONDecoder().decode(Self.self, from: payload)
            guard selection.action == "select", selection.value == "😀",
                ["initial", "updated", "reinstalled"].contains(phase),
                selection.phase == phase
            else { throw ExtensionPeerError.invalidRequest }
            return selection
        }
    }

    struct SelectionReceipt: Encodable {
        let character: String
        let phase: String
        let ledgerCount: Int
    }

    @MainActor
    static func select(
        _ selection: Selection, store: EmojiStore, model: EmojiPanelModel,
        defaults: UserDefaults
    ) throws -> Data {
        guard let emoji = store.catalog.emoji(matching: selection.value),
            emoji.character == selection.value, store.frequent.isEmpty,
            let output = store.fixtureOutput, output.copied.isEmpty, output.inserted.isEmpty
        else { throw ExtensionPeerError.invalidRequest }
        if let data = defaults.data(forKey: AppStorageKeys.Emoji.usage) {
            guard try JSONDecoder().decode(EmojiUsageLedger.self, from: data).entries.isEmpty
            else { throw ExtensionPeerError.invalidRequest }
        }
        model.activate(emoji, copyOnly: true, tone: .standard, store: store, onDismiss: {})
        guard output.copied == [selection.value], output.inserted.isEmpty,
            let data = defaults.data(forKey: AppStorageKeys.Emoji.usage)
        else { throw ExtensionPeerError.unavailable }
        let ledger = try JSONDecoder().decode(EmojiUsageLedger.self, from: data)
        guard ledger.entries.count == 1, let usage = ledger.entries.first,
            usage.character == output.copied.first, usage.count == 1,
            store.frequent.map(\.character) == output.copied
        else { throw ExtensionPeerError.unavailable }
        return try JSONEncoder().encode(
            SelectionReceipt(
                character: usage.character, phase: selection.phase, ledgerCount: usage.count))
    }
    #endif

    @MainActor
    static func execute(
        _ command: String, payload: Data, store: EmojiStore, pick: @MainActor () -> Void
    ) async throws -> Data {
        try await SurfaceCommandService.execute(
            providerID: "emoji", command: command, payload: payload,
            snapshot: { _ in
                snapshot(frequent: store.frequent, character: store.character)
            },
            perform: { action in
                if action == "pick" {
                    pick()
                } else if let emoji = store.frequent.first(where: { "copy:" + $0.id == action }) {
                    store.copy(emoji)
                } else {
                    throw ExtensionPeerError.invalidRequest
                }
            })
    }

    static func snapshot(frequent: [Emoji], character: (Emoji) -> String) -> SurfaceSnapshot {
        .init(
            providerID: "emoji",
            rows: frequent.prefix(100).map { emoji in
                .init(
                    emoji.id, title: character(emoji), detail: String(emoji.name.prefix(256)),
                    icon: "face.smiling", actions: [.init("copy:" + emoji.id, "Copy", "doc.on.doc")]
                )
            }, actions: [.init("pick", "Pick emoji", "face.smiling")],
            message: frequent.isEmpty ? "Choose an emoji to start your frequent list." : nil)
    }
}
