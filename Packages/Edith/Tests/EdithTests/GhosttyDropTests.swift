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
        #expect(payload.files[0].pathExtension == "png")
        #expect(FileManager.default.fileExists(atPath: payload.files[0].path))
        #expect(payload.temporaryFiles == Set(payload.files))
    }

    @Test func tiffOnlyImageDataBecomesAPNGAgentsCanAttach() throws {
        let board = NSPasteboard(name: .init("edith.drop.tiff-data"))
        board.clearContents()
        let item = NSPasteboardItem()
        item.setData(try #require(Self.redSquare().tiffRepresentation), forType: .tiff)
        board.writeObjects([item])

        let payload = try #require(TerminalDropPayload.files(from: board))
        defer { payload.removeTemporaryFiles() }

        #expect(payload.files[0].pathExtension == "png")
        let written = try Data(contentsOf: payload.files[0])
        #expect(written.starts(with: [0x89, 0x50, 0x4E, 0x47]))
    }

    @Test func aPNGOfferedBesideTIFFIsKeptUnchanged() throws {
        let board = NSPasteboard(name: .init("edith.drop.png-and-tiff"))
        board.clearContents()
        let image = Self.redSquare()
        let bitmap = try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        let item = NSPasteboardItem()
        item.setData(try #require(image.tiffRepresentation), forType: .tiff)
        item.setData(png, forType: .png)
        board.writeObjects([item])

        let payload = try #require(TerminalDropPayload.files(from: board))
        defer { payload.removeTemporaryFiles() }

        #expect(payload.files[0].pathExtension == "png")
        #expect(try Data(contentsOf: payload.files[0]) == png)
    }

    @Test func jpegImageDataKeepsItsFormat() throws {
        let board = NSPasteboard(name: .init("edith.drop.jpeg-data"))
        board.clearContents()
        let bitmap = try #require(
            Self.redSquare().tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        let jpeg = try #require(bitmap.representation(using: .jpeg, properties: [:]))
        let item = NSPasteboardItem()
        item.setData(jpeg, forType: .init("public.jpeg"))
        board.writeObjects([item])

        let payload = try #require(TerminalDropPayload.files(from: board))
        defer { payload.removeTemporaryFiles() }

        #expect(["jpeg", "jpg"].contains(payload.files[0].pathExtension))
        #expect(try Data(contentsOf: payload.files[0]) == jpeg)
    }

    private static func redSquare() -> NSImage {
        let image = NSImage(size: NSSize(width: 2, height: 2))
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 2, height: 2).fill()
        image.unlockFocus()
        return image
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

    @Test @MainActor func anInactiveTerminalStackedAboveDoesNotCatchTheDrop() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let visible = GhosttyTerminalView(
            launch: GhosttyLaunch(executable: "/bin/cat", arguments: [], environment: []))
        let stacked = GhosttyTerminalView(
            launch: GhosttyLaunch(executable: "/bin/cat", arguments: [], environment: []))
        for view in [visible, stacked] {
            view.frame = container.bounds
            container.addSubview(view)
        }
        let center = NSPoint(x: container.bounds.midX, y: container.bounds.midY)

        stacked.setRenderingActive(false)
        let reachesVisible = container.hitTest(center) === visible
        #expect(reachesVisible)

        stacked.setRenderingActive(true)
        let reachesStacked = container.hitTest(center) === stacked
        #expect(reachesStacked)
    }

    @Test func promisedFilesAreRegisteredAsDropTypes() {
        let promiseTypes = Set(
            NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) })

        #expect(!promiseTypes.isDisjoint(with: Set(TerminalDropPayload.pasteboardTypes)))
    }
}
