import AppKit
import Foundation
import GhosttyKit
@testable import GhosttyTerminal
import Testing

@Suite(.serialized) struct GhosttyClipboardTests {
    @Test(arguments: [false, true]) @MainActor
    func selectingTextCopiesPlainTextWithLogicalLineFormatting(themed: Bool) async throws {
        _ = TestWindowHost.application
        let board = NSPasteboard.general
        let previous = (board.types ?? []).compactMap { type in
            board.data(forType: type).map { (type, $0) }
        }
        defer {
            board.declareTypes(previous.map(\.0), owner: nil)
            for (type, data) in previous { board.setData(data, forType: type) }
        }
        let wrapped = String(repeating: "wrapped text ", count: 20) + "end"
        let command =
            "printf '\\033[2J\\033[3J\\033[H\\033[31m  first\\033[0m   \\r\\n\\r\\n    café 😀   \\r\\n\(wrapped)'; exec cat"
        let theme = GhosttyTheme(
            background: "#111111", foreground: "#eeeeee", cursor: "#eeeeee", fontSize: 13)
        let view = GhosttyTerminalView(
            launch: GhosttyLaunch(
                executable: "/bin/sh", arguments: ["-c", command], environment: []),
            theme: themed ? theme : nil)
        view.frame = NSRect(x: 0, y: 0, width: 400, height: 600)
        let window = TestWindowHost.window(contentRect: view.frame)
        window.contentView = view
        defer {
            window.contentView = nil
            view.shutdown()
        }
        let surface = try #require(view.surface)
        for _ in 0..<100 {
            _ = view.performBindingAction("select_all")
            if view.selectedText()?.contains("end") == true { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        board.declareTypes([.string, .html], owner: nil)
        board.setString("old clipboard", forType: .string)
        board.setString("<b>old clipboard</b>", forType: .html)

        view.selectAllTerminalText(nil)

        #expect(board.string(forType: .string) == "first\n\n    café 😀\n\(wrapped)")
        #expect(board.string(forType: .html) == nil)
        #expect(ghostty_surface_has_selection(surface))
        #expect(view.performBindingAction("select_all"))
        view.selectionChanged()
        try await Task.sleep(for: .milliseconds(150))
        #expect(board.string(forType: .string) == "first\n\n    café 😀\n\(wrapped)")

        view.keyDown(
            with: try #require(
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [], timestamp: 1,
                    windowNumber: window.windowNumber, context: nil, characters: "x",
                    charactersIgnoringModifiers: "x", isARepeat: false, keyCode: 7)))
        try await Task.sleep(for: .milliseconds(150))
        #expect(!view.hasSelection)
        #expect(board.string(forType: .string) == "first\n\n    café 😀\n\(wrapped)")
    }

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
