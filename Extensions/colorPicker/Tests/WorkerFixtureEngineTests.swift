import EdithExtensionSupport
import Foundation
import Testing
import WorkerFixtureSupport
import WorkerFixtureTestSupport
@testable import ColorPickerExtension

@MainActor @Suite(.serialized) struct WorkerFixtureEngineTests {
    private func fixture(_ owner: String) throws -> EngineFixture {
        let suite = try #require(ProcessInfo.processInfo.environment["EDITH_SHARED_DEFAULTS_SUITE"])
        try #require(suite.hasPrefix("edith.") && suite.contains(".tests."))
        return try EngineFixture(owner: owner)
    }

    @Test func colorSamplingAndCopyStayInOwnedSink() throws {
        let value = try fixture("colorPicker"); defer { value.remove() }
        let admission = try #require(try value.admit())
        let engine = ColorPickerStore(fixture: admission)
        #expect(engine.systemResourceCount == 0)
        engine.registerHotKey()
        engine.pick()
        #expect(!engine.history.isEmpty)
        #expect(engine.fixtureCopies.count == 1)
        let swatch = try #require(engine.history.first)
        engine.copyDefault(swatch)
        #expect(engine.fixtureCopies.count == 2)
        for index in 0..<256 { #expect(engine.writeFixtureCopy(String(index))) }
        #expect(engine.fixtureCopies.count == 128)
        #expect(engine.fixtureCopies.last == "255")
        engine.shutdown()
        engine.pick()
        #expect(!engine.writeFixtureCopy("stopped"))
        #expect(engine.fixtureCopies.count == 128)
        #expect(engine.systemResourceCount == 0)
    }

}
