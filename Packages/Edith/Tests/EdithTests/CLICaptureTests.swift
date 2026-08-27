import ArgumentParser
import Testing

@testable import EdithCLI

@Suite struct CLICaptureTests {
    @Test func parsesReadAndScreenshotLeaves() throws {
        #expect(try EdRoot.parseAsRoot(["capture", "read"]) is CaptureReadCommand)
        #expect(
            try EdRoot.parseAsRoot(["capture", "screenshot", "--json"])
                is CaptureScreenshotCommand)
    }

    @Test func commandTreeMatchesTheParserSurface() throws {
        let capture = try #require(CommandTree.root.child("capture"))
        #expect(capture.children.map(\.name) == ["read", "screenshot"])
        #expect(capture.children.allSatisfy { $0.options.contains("--json") })
    }
}
