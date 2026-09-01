import AppKit
import Foundation
@testable import GhosttyTerminal
import Testing

@Suite(.serialized) struct GhosttyClipboardTests {
    @Test func mixedCopyKeepsEachRepresentationInItsOwnPasteboardType() throws {
        let board = NSPasteboard(name: .init("edith.ghostty.copy.mixed"))
        let metadata = TerminalClipboardEntry(
            mime: "application/x-ghostty-terminal", data: Data("term_65a6778b".utf8))

        TerminalClipboard.write(
            [
                metadata,
                TerminalClipboardEntry(
                    mime: "text/plain;charset=utf-8", data: Data("normal text".utf8)),
                TerminalClipboardEntry(
                    mime: "text/html",
                    data: Data("<div style=\"white-space: pre\">normal text</div>".utf8)),
            ],
            to: board)

        #expect(board.string(forType: .string) == "normal text")
        #expect(
            board.string(forType: .html)
                == "<div style=\"white-space: pre\">normal text</div>")
        #expect(board.data(forType: metadata.pasteboardType) == Data("term_65a6778b".utf8))
    }

    @Test func duplicateRepresentationsDoNotDuplicatePasteboardTypes() {
        let board = NSPasteboard(name: .init("edith.ghostty.copy.duplicate"))

        TerminalClipboard.write(
            [
                TerminalClipboardEntry(mime: "text/plain", data: Data("first".utf8)),
                TerminalClipboardEntry(
                    mime: "text/plain; charset=utf-8", data: Data("latest".utf8)),
            ],
            to: board)

        #expect(board.types?.filter { $0 == .string }.count == 1)
        #expect(board.string(forType: .string) == "latest")
    }
}
