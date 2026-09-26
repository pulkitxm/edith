import AppKit
import EdithStudio
import PDFKit
import Testing

@testable import Edith

@MainActor
final class StudioCanvasRig {
    let editor: StudioPDFEditorModel
    let canvas: StudioPDFCanvasView
    let coordinator: StudioPDFCanvas.Coordinator
    let window: NSWindow

    init(url: URL) throws {
        editor = StudioPDFEditorModel(url: url, mode: .redact)
        editor.load()
        canvas = StudioPDFCanvasView(frame: NSRect(x: 0, y: 0, width: 760, height: 980))
        coordinator = StudioPDFCanvas.Coordinator(editor: editor)
        canvas.coordinator = coordinator
        canvas.autoScales = true
        canvas.displayMode = .singlePage
        canvas.document = editor.session?.document
        window = TestWindowHost.window(contentRect: canvas.frame)
        window.contentView = canvas
        window.orderBack(nil)
        canvas.layoutDocumentView()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
        sync()
    }

    var page: PDFPage {
        get throws { try #require(editor.session?.page(0)) }
    }

    var marks: [CGRect] { editor.session?.redactions[0] ?? [] }

    func sync() {
        canvas.tool = editor.tool
        canvas.selectedAnnotation = editor.selected
    }

    func view(_ point: CGPoint) throws -> NSPoint {
        canvas.convert(point, from: try page)
    }

    func pagePoint(_ point: NSPoint) throws -> CGPoint {
        canvas.convert(point, to: try page)
    }

    func mouse(_ type: NSEvent.EventType, _ point: NSPoint) throws -> NSEvent {
        try #require(
            NSEvent.mouseEvent(
                with: type, location: canvas.convert(point, to: nil), modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                clickCount: 1, pressure: 1))
    }

    func drag(from start: NSPoint, to end: NSPoint) throws {
        canvas.mouseDown(with: try mouse(.leftMouseDown, start))
        sync()
        for step in 1...4 {
            let fraction = CGFloat(step) / 4
            let point = NSPoint(
                x: start.x + (end.x - start.x) * fraction, y: start.y + (end.y - start.y) * fraction
            )
            canvas.mouseDragged(with: try mouse(.leftMouseDragged, point))
        }
        canvas.mouseUp(with: try mouse(.leftMouseUp, end))
        sync()
    }

    static func characters(for code: UInt16) -> String {
        let scalar: Int =
            switch code {
            case 51: 0x7F
            case 53: 0x1B
            case 117: NSDeleteFunctionKey
            case 123: NSLeftArrowFunctionKey
            case 124: NSRightArrowFunctionKey
            case 125: NSDownArrowFunctionKey
            case 126: NSUpArrowFunctionKey
            default: 0x20
            }
        return UnicodeScalar(scalar).map { String(Character($0)) } ?? " "
    }

    func key(_ code: UInt16, shift: Bool = false) throws {
        let characters = Self.characters(for: code)
        let event = try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: shift ? [.shift] : [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil,
                characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: code))
        canvas.keyDown(with: event)
        sync()
    }

    func close() { window.orderOut(nil) }
}

@MainActor
@Suite(.serialized) struct StudioPDFCanvasTests {
    func document(rotation: Int = 0) throws -> URL {
        let folder = try StudioTestFiles.folder()
        let source = folder.appendingPathComponent("Statement.pdf")
        try StudioTestFiles.pdf(source, pages: ["Account holder Jane Example", "Second page"])
        guard rotation != 0 else { return source }
        let document = try #require(PDFDocument(url: source))
        document.page(at: 0)?.rotation = rotation
        let rotated = folder.appendingPathComponent("Rotated.pdf")
        #expect(document.write(to: rotated))
        return rotated
    }

    func near(_ a: CGFloat, _ b: CGFloat, _ tolerance: CGFloat = 1.5) -> Bool {
        abs(a - b) <= tolerance
    }

    @Test func drawingAMarkSelectsItAndDraggingItMovesIt() throws {
        let rig = try StudioCanvasRig(url: try document())
        defer { rig.close() }
        #expect(rig.editor.tool == .redact)
        try rig.drag(
            from: try rig.view(CGPoint(x: 100, y: 500)), to: try rig.view(CGPoint(x: 300, y: 560)))
        #expect(rig.marks.count == 1)
        let drawn = try #require(rig.marks.first)
        #expect(near(drawn.minX, 100) && near(drawn.minY, 500))
        #expect(near(drawn.width, 200) && near(drawn.height, 60))
        #expect(rig.editor.selectedRedaction != nil)
        try rig.drag(
            from: try rig.view(CGPoint(x: 200, y: 530)), to: try rig.view(CGPoint(x: 240, y: 560)))
        #expect(rig.marks.count == 1)
        let moved = try #require(rig.marks.first)
        #expect(near(moved.minX, drawn.minX + 40) && near(moved.minY, drawn.minY + 30))
        #expect(near(moved.width, drawn.width) && near(moved.height, drawn.height))
    }

    @Test func handlesResizeTheSelectedMark() throws {
        let rig = try StudioCanvasRig(url: try document())
        defer { rig.close() }
        try rig.drag(
            from: try rig.view(CGPoint(x: 100, y: 400)), to: try rig.view(CGPoint(x: 220, y: 440)))
        let drawn = try #require(rig.marks.first)
        let corner = try rig.view(CGPoint(x: drawn.maxX, y: drawn.maxY))
        let target = try rig.view(CGPoint(x: drawn.maxX + 60, y: drawn.maxY + 20))
        try rig.drag(from: corner, to: target)
        let grown = try #require(rig.marks.first)
        #expect(rig.marks.count == 1)
        #expect(near(grown.minX, drawn.minX) && near(grown.minY, drawn.minY))
        #expect(near(grown.maxX, drawn.maxX + 60) && near(grown.maxY, drawn.maxY + 20))
        let left = try rig.view(CGPoint(x: grown.minX, y: grown.midY))
        let pastRight = try rig.view(CGPoint(x: grown.maxX + 80, y: grown.midY))
        try rig.drag(from: left, to: pastRight)
        let squeezed = try #require(rig.marks.first)
        #expect(squeezed.width >= StudioPDFGrip.minimumSide - 0.01)
        #expect(near(squeezed.maxX, grown.maxX))
    }

    @Test func keysNudgeDeleteAndUndoMarks() throws {
        let rig = try StudioCanvasRig(url: try document())
        defer { rig.close() }
        try rig.drag(
            from: try rig.view(CGPoint(x: 100, y: 300)), to: try rig.view(CGPoint(x: 180, y: 330)))
        let drawn = try #require(rig.marks.first)
        try rig.key(124)
        let right = try #require(rig.marks.first)
        #expect(near(right.minX, drawn.minX + 1, 0.2) && near(right.minY, drawn.minY, 0.2))
        try rig.key(126, shift: true)
        let up = try #require(rig.marks.first)
        #expect(near(up.minY, drawn.minY + 10, 0.2))
        try rig.key(51)
        #expect(rig.marks.isEmpty)
        #expect(rig.editor.selected == nil)
        rig.editor.undo()
        #expect(rig.marks.count == 1)
    }

    @Test func clickingAMarkNeverStacksAnotherOne() throws {
        let rig = try StudioCanvasRig(url: try document())
        defer { rig.close() }
        try rig.drag(
            from: try rig.view(CGPoint(x: 100, y: 600)), to: try rig.view(CGPoint(x: 260, y: 640)))
        let inside = try rig.view(CGPoint(x: 150, y: 620))
        try rig.drag(from: inside, to: inside)
        #expect(rig.marks.count == 1)
        try rig.drag(
            from: try rig.view(CGPoint(x: 300, y: 200)), to: try rig.view(CGPoint(x: 301, y: 200.5))
        )
        #expect(rig.marks.count == 1)
        try rig.key(53)
        #expect(rig.editor.selected == nil)
    }

    @Test func rotatedPagesResizeAlongTheDraggedEdge() throws {
        let rig = try StudioCanvasRig(url: try document(rotation: 90))
        defer { rig.close() }
        try rig.drag(
            from: try rig.view(CGPoint(x: 120, y: 420)), to: try rig.view(CGPoint(x: 260, y: 470)))
        let drawn = try #require(rig.marks.first)
        #expect(near(drawn.width, 140) && near(drawn.height, 50))
        let grip = StudioPDFGrip(right: true)
        let handle = try rig.view(grip.anchor(in: drawn))
        let target = NSPoint(x: handle.x + 30, y: handle.y + 30)
        let from = try rig.pagePoint(handle)
        let to = try rig.pagePoint(target)
        try rig.drag(from: handle, to: target)
        let resized = try #require(rig.marks.first)
        let expected = grip.apply(to: drawn, delta: CGPoint(x: to.x - from.x, y: to.y - from.y))
        #expect(near(resized.minX, expected.minX) && near(resized.maxX, expected.maxX))
        #expect(near(resized.minY, drawn.minY) && near(resized.maxY, drawn.maxY))
    }

    @Test func savedFileRedactsWhatTheCanvasShows() async throws {
        let url = try document()
        let rig = try StudioCanvasRig(url: url)
        defer { rig.close() }
        let page = try rig.page
        let found = try #require(
            rig.editor.session?.document.findString("Jane Example", withOptions: []).first)
        let bounds = found.bounds(for: page)
        try rig.drag(
            from: try rig.view(CGPoint(x: bounds.minX + 37, y: bounds.minY - 3)),
            to: try rig.view(CGPoint(x: bounds.maxX + 43, y: bounds.maxY + 3)))
        let drawn = try #require(rig.marks.first)
        try rig.drag(
            from: try rig.view(CGPoint(x: drawn.midX, y: drawn.midY)),
            to: try rig.view(CGPoint(x: drawn.midX - 40, y: drawn.midY)))
        let output = url.deletingLastPathComponent().appendingPathComponent("Statement out.pdf")
        let studio = StudioModel(defaults: StudioTestFiles.defaults(), loadsState: false)
        rig.editor.save(to: output, studio: studio)
        #expect(await StudioTestFiles.waitUntil(timeout: 60) { !rig.editor.isSaving })
        let text = PDFDocument(url: output)?.string ?? ""
        #expect(!text.contains("Jane"))
        #expect(!text.contains("Example"))
        #expect(text.contains("Second"))
    }
}

@Suite struct StudioPDFGripTests {
    @Test func cornerAndEdgeHandlesMoveOnlyTheirEdges() {
        let rect = CGRect(x: 10, y: 20, width: 100, height: 50)
        let corner = StudioPDFGrip(right: true, top: true).apply(
            to: rect, delta: CGPoint(x: 5, y: 7))
        #expect(corner == CGRect(x: 10, y: 20, width: 105, height: 57))
        let edge = StudioPDFGrip(left: true).apply(to: rect, delta: CGPoint(x: 30, y: 99))
        #expect(edge == CGRect(x: 40, y: 20, width: 70, height: 50))
        let moved = StudioPDFGrip.move.apply(to: rect, delta: CGPoint(x: -4, y: 3))
        #expect(moved == CGRect(x: 6, y: 23, width: 100, height: 50))
    }

    @Test func handlesNeverInvertTheRect() {
        let rect = CGRect(x: 0, y: 0, width: 40, height: 40)
        let squeezed = StudioPDFGrip(left: true, bottom: true).apply(
            to: rect, delta: CGPoint(x: 500, y: 500))
        #expect(squeezed.width == StudioPDFGrip.minimumSide)
        #expect(squeezed.height == StudioPDFGrip.minimumSide)
        #expect(squeezed.maxX == 40 && squeezed.maxY == 40)
    }

    @Test func anchorsSitOnCornersAndEdgeMidpoints() {
        let rect = CGRect(x: 0, y: 0, width: 20, height: 10)
        let anchors = StudioPDFGrip.handles.map { $0.anchor(in: rect) }
        #expect(anchors.count == 8)
        #expect(anchors.contains(CGPoint(x: 0, y: 0)))
        #expect(anchors.contains(CGPoint(x: 20, y: 10)))
        #expect(anchors.contains(CGPoint(x: 10, y: 0)))
        #expect(anchors.contains(CGPoint(x: 0, y: 5)))
        #expect(!anchors.contains(CGPoint(x: 10, y: 5)))
    }

    @Test func nudgesHaveTheRequestedLength() {
        let step = StudioPDFGrip.nudge(CGPoint(x: 0, y: -250), by: 10)
        #expect(step == CGPoint(x: 0, y: -10))
        #expect(StudioPDFGrip.nudge(.zero, by: 10) == .zero)
    }
}
