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
}
