import ArgumentParser
import Testing

@testable import EdithCLI

@Suite struct CLICaptureTests {
    @Test func parsesCaptureStudioLeaves() throws {
        #expect(try EdRoot.parseAsRoot(["capture"]) is CaptureReadCommand)
        #expect(try EdRoot.parseAsRoot(["capture", "read"]) is CaptureReadCommand)
        #expect(try EdRoot.parseAsRoot(["capture", "area", "--json"]) is CaptureAreaCommand)
        #expect(try EdRoot.parseAsRoot(["capture", "window"]) is CaptureWindowCommand)
        #expect(try EdRoot.parseAsRoot(["capture", "screen"]) is CaptureScreenCommand)
        #expect(try EdRoot.parseAsRoot(["capture", "library"]) is CaptureLibraryCommand)
    }

    @Test func commandTreeMatchesTheParserSurface() throws {
        let capture = try #require(CommandTree.root.child("capture"))
        #expect(capture.children.map(\.name) == ["read", "area", "window", "screen", "library"])
        #expect(capture.children.allSatisfy { $0.options.contains("--json") })
    }
}
