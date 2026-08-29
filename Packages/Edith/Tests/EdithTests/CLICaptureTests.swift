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
        #expect(try EdRoot.parseAsRoot(["capture", "record"]) is CaptureRecordAreaCommand)
        #expect(
            try EdRoot.parseAsRoot(["capture", "record", "window"]) is CaptureRecordWindowCommand)
        #expect(
            try EdRoot.parseAsRoot(["capture", "record", "display"]) is CaptureRecordDisplayCommand)
        #expect(
            try EdRoot.parseAsRoot(["capture", "record", "pause"]) is CaptureRecordPauseCommand)
        #expect(
            try EdRoot.parseAsRoot(["capture", "record", "resume"]) is CaptureRecordResumeCommand)
        #expect(try EdRoot.parseAsRoot(["capture", "record", "stop"]) is CaptureRecordStopCommand)
        #expect(
            try EdRoot.parseAsRoot(["capture", "record", "cancel"]) is CaptureRecordCancelCommand)
        #expect(
            try EdRoot.parseAsRoot(["capture", "record", "status", "--json"])
                is CaptureRecordStatusCommand)
        #expect(
            try EdRoot.parseAsRoot(["capture", "record", "library"]) is CaptureRecordLibraryCommand)
    }

    @Test func commandTreeMatchesTheParserSurface() throws {
        let capture = try #require(CommandTree.root.child("capture"))
        #expect(
            capture.children.map(\.name) == [
                "read", "area", "window", "screen", "library", "record",
            ])
        #expect(capture.children.dropLast().allSatisfy { $0.options.contains("--json") })
        let record = try #require(capture.child("record"))
        #expect(
            record.children.map(\.name) == [
                "area", "window", "display", "pause", "resume", "stop", "cancel", "status",
                "library",
            ])
        #expect(record.children.allSatisfy { $0.options.contains("--json") })
    }
}
