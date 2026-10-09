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

    @Test func readsOnlyRequestedRepresentationsAndListsCanonicalMIMETypes() throws {
        let board = NSPasteboard(name: .init("edith.ghostty.read.mixed"))
        board.declareTypes([.string, .html], owner: nil)
        board.setString("paste me", forType: .string)
        board.setData(Data("<b>paste me</b>".utf8), forType: .html)

        let request = try #require(
            TerminalClipboard.read(
                requestedMIMEs: ["text/plain", "text/plain"], listAvailable: true,
                from: board))

        #expect(
            request.entries == [
                TerminalClipboardEntry(mime: "text/plain", data: Data("paste me".utf8))
            ])
        #expect(request.availableMIMEs.contains("text/plain"))
        #expect(request.availableMIMEs.contains("text/html"))
    }

    @Test func anUnavailableRequestedRepresentationDoesNotStartARead() {
        let board = NSPasteboard(name: .init("edith.ghostty.read.unavailable"))
        board.clearContents()

        #expect(
            TerminalClipboard.read(
                requestedMIMEs: ["text/plain"], listAvailable: false, from: board) == nil)
    }
}
