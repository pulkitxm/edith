import EdithExtensionSupport
import Foundation
import Testing
@testable import EmojiExtension

struct EmojiExtensionSurfaceTests {
    @Test func liveStateIsPreservedInTheSurfaceContract() throws {
        let emoji = Emoji(character: "🐈", name: "cat", groupIndex: 0, unicodeVersion: 1)
        let snapshot = EmojiSurface.snapshot(frequent: [emoji], character: { $0.character })
        #expect(snapshot.rows.first?.title == "🐈")
        #expect(snapshot.rows.first?.detail == "cat")
        #expect(snapshot.rows.first?.actions.first?.id == "copy:🐈")
        #expect(snapshot.actions.first?.id == "pick")
        #expect(EmojiSurface.snapshot(frequent: [], character: { $0.character }).message != nil)
        _ = try SurfaceSnapshot.decode(snapshot.encoded(), providerID: "emoji")
    }
    @Test @MainActor func copyActionsResolveTheOwnedFrequentCatalogAndRejectArbitraryCharacters()
        async throws
    {
        let fixture = EmojiDefaultsFixture()
        let cat = Emoji(character: "🐈", name: "cat", groupIndex: 0, unicodeVersion: 1)
        let store = EmojiStore(
            defaults: fixture.defaults, writePasteboard: fixture.writePasteboard,
            catalog: .init(groups: [], emoji: [cat]), insertionDelay: .zero,
            typeCharacter: { _ in false })
        defer { store.shutdown() }
        store.copy(cat)
        var opened = false
        let request = SurfaceSnapshotRequest(target: .notch, tile: .init(.desk))
        let copy = SurfaceActionRequest(snapshot: request, actionID: "copy:🐈")
        _ = try await EmojiSurface.execute(
            "surface.perform", payload: copy.encoded(providerID: "emoji"), store: store,
            pick: { opened = true })
        #expect(fixture.pasteboard.string(forType: .string) == "🐈")
        #expect(!opened)
        let invalid = SurfaceActionRequest(snapshot: request, actionID: "copy:arbitrary")
        await #expect(throws: ExtensionPeerError.self) {
            _ = try await EmojiSurface.execute(
                "surface.perform", payload: invalid.encoded(providerID: "emoji"), store: store,
                pick: { opened = true })
        }
        #expect(fixture.pasteboard.string(forType: .string) == "🐈")
        let pick = SurfaceActionRequest(snapshot: request, actionID: "pick")
        _ = try await EmojiSurface.execute(
            "surface.perform", payload: pick.encoded(providerID: "emoji"), store: store,
            pick: { opened = true })
        #expect(opened)
    }

}
