import AppKit
import Testing

@testable import GhosttyTerminal

@Suite struct GhosttyDropTests {
    @Test func aDroppedFileArrivesAsAQuotedPath() {
        let board = NSPasteboard(name: .init("edith.drop.file"))
        board.clearContents()
        board.writeObjects([URL(fileURLWithPath: "/Users/pulkit/a file.png") as NSURL])
        #expect(GhosttyTerminalView.dropped(from: board) == "'/Users/pulkit/a file.png'")
    }

    @Test func aPlainPathNeedsNoQuoting() {
        #expect(GhosttyTerminalView.quote("/tmp/shot.png") == "/tmp/shot.png")
        #expect(GhosttyTerminalView.quote("/tmp/my shot.png") == "'/tmp/my shot.png'")
        #expect(GhosttyTerminalView.quote("/tmp/it's.png") == #"'/tmp/it'\''s.png'"#)
    }

    @Test func severalFilesArriveSeparated() {
        let board = NSPasteboard(name: .init("edith.drop.many"))
        board.clearContents()
        board.writeObjects([
            URL(fileURLWithPath: "/tmp/one.png") as NSURL,
            URL(fileURLWithPath: "/tmp/two three.png") as NSURL,
        ])
        #expect(GhosttyTerminalView.dropped(from: board) == "/tmp/one.png '/tmp/two three.png'")
    }

    @Test func droppedTextArrivesUnchanged() {
        let board = NSPasteboard(name: .init("edith.drop.text"))
        board.clearContents()
        board.setString("hello there", forType: .string)
        #expect(GhosttyTerminalView.dropped(from: board) == "hello there")
    }

    @Test func anEmptyPasteboardDropsNothing() {
        let board = NSPasteboard(name: .init("edith.drop.empty"))
        board.clearContents()
        #expect(GhosttyTerminalView.dropped(from: board) == nil)
    }
}
