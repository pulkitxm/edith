import EdithExtensionSupport
import Foundation

enum EmojiSurface {
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
