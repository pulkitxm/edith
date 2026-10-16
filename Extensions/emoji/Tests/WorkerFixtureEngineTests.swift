import EdithExtensionSupport
import Foundation
import Testing
import WorkerFixtureSupport
import WorkerFixtureTestSupport
@testable import EmojiExtension

@MainActor @Suite(.serialized) struct WorkerFixtureEngineTests {
    private func fixture(_ owner: String) throws -> EngineFixture {
        let suite = try #require(ProcessInfo.processInfo.environment["EDITH_SHARED_DEFAULTS_SUITE"])
        try #require(suite.hasPrefix("edith.") && suite.contains(".tests."))
        return try EngineFixture(owner: owner)
    }

    @Test func emojiInsertionAndCopyUseOwnedSink() async throws {
        let value = try fixture("emoji"); defer { value.remove() }
        let admission = try #require(try value.admit())
        let engine = EmojiStore(fixture: admission)
        let emoji = try #require(engine.catalog.emoji.first)
        let character = engine.character(for: emoji)
        #expect(try await engine.insertAndWait(character: character))
        engine.copy(emoji)
        #expect(engine.fixtureOutput?.inserted == [character])
        #expect(engine.fixtureOutput?.copied == [character])
        for _ in 0..<256 { engine.copy(emoji) }
        #expect(engine.fixtureOutput?.copied.count == 128)
        #expect(engine.fixtureOutput?.copied.allSatisfy { $0 == character } == true)
        engine.shutdown()
        #expect(try await !engine.insertAndWait(character: character))
    }

}
