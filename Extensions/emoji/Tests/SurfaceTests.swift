import EdithExtensionSupport
import Foundation
import Testing
@testable import EmojiExtension

struct EmojiExtensionSurfaceTests {
    @Test func tileOffersOnlyTheChooseEmojiAction() throws {
        let snapshot = EmojiSurface.snapshot()
        #expect(snapshot.rows.isEmpty)
        #expect(snapshot.metrics.isEmpty)
        #expect(snapshot.actions.map(\.id) == ["pick"])
        #expect(snapshot.actions.first?.title == "Choose emoji")
        #expect(snapshot.message == "Choose an emoji to insert into your current app.")
        _ = try SurfaceSnapshot.decode(snapshot.encoded(), providerID: "emoji")
    }

    @Test @MainActor func onlyThePickActionIsAccepted() async throws {
        let fixture = EmojiDefaultsFixture()
        let cat = Emoji(character: "🐈", name: "cat", groupIndex: 0, unicodeVersion: 1)
        let store = EmojiStore(
            defaults: fixture.defaults, writePasteboard: fixture.writePasteboard,
            catalog: .init(groups: [], emoji: [cat]), insertionDelay: .zero,
            typeCharacter: { _ in false })
        defer { store.shutdown() }
        var opened = false
        let request = SurfaceSnapshotRequest(target: .notch, tile: .init(.desk))
        let copy = SurfaceActionRequest(snapshot: request, actionID: "copy:🐈")
        await #expect(throws: ExtensionPeerError.self) {
            _ = try await EmojiSurface.execute(
                "surface.perform", payload: copy.encoded(providerID: "emoji"), store: store,
                pick: { opened = true })
        }
        #expect(!opened)
        let pick = SurfaceActionRequest(snapshot: request, actionID: "pick")
        _ = try await EmojiSurface.execute(
            "surface.perform", payload: pick.encoded(providerID: "emoji"), store: store,
            pick: { opened = true })
        #expect(opened)
    }
}
