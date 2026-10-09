import EdithExtensionSupport
import Foundation

enum EmojiSurface {
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
