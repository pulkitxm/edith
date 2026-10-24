import EdithExtensionSupport
import Foundation

enum EmojiSurface {

    @MainActor
    static func execute(
        _ command: String, payload: Data, store: EmojiStore, pick: @MainActor () -> Void
    ) async throws -> Data {
        try await SurfaceCommandService.execute(
            providerID: "emoji", command: command, payload: payload,
            snapshot: { _ in snapshot() },
            perform: { action in
                guard action == "pick" else { throw ExtensionPeerError.invalidRequest }
                pick()
            })
    }

    static func snapshot() -> SurfaceSnapshot {
        .init(
            providerID: "emoji",
            actions: [.init("pick", "Choose emoji", "face.smiling")],
            message: "Choose an emoji to insert into your current app.")
    }
}
