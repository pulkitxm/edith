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

    @Test func imageDataBecomesADurableTemporaryFile() throws {
        let board = NSPasteboard(name: .init("edith.drop.image-data"))
        board.clearContents()
        let image = NSImage(size: NSSize(width: 2, height: 2))
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 2, height: 2).fill()
        image.unlockFocus()
        board.writeObjects([image])

        let payload = try #require(TerminalDropPayload.files(from: board))
        defer { payload.removeTemporaryFiles() }

        #expect(payload.files.count == 1)
        #expect(["png", "tiff"].contains(payload.files[0].pathExtension))
        #expect(FileManager.default.fileExists(atPath: payload.files[0].path))
        #expect(payload.temporaryFiles == Set(payload.files))
    }

    @Test func pdfDataBecomesATemporaryPDF() throws {
        let board = NSPasteboard(name: .init("edith.drop.pdf-data"))
        board.clearContents()
        let item = NSPasteboardItem()
        let data = Data("%PDF-1.7 terminal drop".utf8)
        item.setData(data, forType: .pdf)
        board.writeObjects([item])

        let payload = try #require(TerminalDropPayload.files(from: board))
        defer { payload.removeTemporaryFiles() }

        #expect(payload.files[0].pathExtension == "pdf")
        #expect(try Data(contentsOf: payload.files[0]) == data)
    }

    @Test func videoDataKeepsItsMediaExtension() throws {
        let board = NSPasteboard(name: .init("edith.drop.video-data"))
        board.clearContents()
        let item = NSPasteboardItem()
        let data = Data([0, 0, 0, 20, 102, 116, 121, 112])
        item.setData(data, forType: .init("public.mpeg-4"))
        board.writeObjects([item])

        let payload = try #require(TerminalDropPayload.files(from: board))
        defer { payload.removeTemporaryFiles() }

        #expect(payload.files[0].pathExtension == "mp4")
        #expect(try Data(contentsOf: payload.files[0]) == data)
    }

    @Test func audioDataKeepsItsMediaExtension() throws {
        let board = NSPasteboard(name: .init("edith.drop.audio-data"))
        board.clearContents()
        let item = NSPasteboardItem()
        let data = Data("ID3".utf8)
        item.setData(data, forType: .init("public.mp3"))
        board.writeObjects([item])

        let payload = try #require(TerminalDropPayload.files(from: board))
        defer { payload.removeTemporaryFiles() }

        #expect(payload.files[0].pathExtension == "mp3")
        #expect(try Data(contentsOf: payload.files[0]) == data)
    }

    @Test func browserURLDropsAreShellEscaped() {
        let board = NSPasteboard(name: .init("edith.drop.url"))
        board.clearContents()
        board.setString("https://example.com/?one=1&two=2", forType: .URL)

        #expect(
            GhosttyTerminalView.dropped(from: board)
                == "'https://example.com/?one=1&two=2'")
    }

    @Test func promisedFilesAreRegisteredAsDropTypes() {
        let promiseTypes = Set(
            NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) })

        #expect(!promiseTypes.isDisjoint(with: Set(TerminalDropPayload.pasteboardTypes)))
    }
}
