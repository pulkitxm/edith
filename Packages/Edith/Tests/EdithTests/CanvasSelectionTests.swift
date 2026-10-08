import AppKit
import EdithKit
import EdithStudio
import SwiftUI
import Testing

@testable import Edith

@MainActor
@Suite(.serialized) struct CanvasSelectionTests {
    @Test(arguments: [0, 1, 2, 3])
    func resizingKeepsTheOppositeCornerFixed(corner: Int) {
        let frame = CGRect(x: 0.2, y: 0.3, width: 0.4, height: 0.2)
        let resized = CanvasSelectionGeometry.resize(
            frame, corner: corner, delta: CGPoint(x: 0.05, y: 0.04))
        let fixed = CanvasSelectionGeometry.anchor(3 - corner, in: resized)
        let original = CanvasSelectionGeometry.anchor(3 - corner, in: frame)
        #expect(hypot(fixed.x - original.x, fixed.y - original.y) < 0.0001)
        let collapsed = CanvasSelectionGeometry.resize(
            frame, corner: corner,
            delta: CGPoint(x: corner % 2 == 0 ? 4 : -4, y: corner < 2 ? 4 : -4))
        #expect(collapsed.width >= 0.0199)
        #expect(collapsed.height >= 0.0199)
    }

    @Test func imageAspectRatioStaysStable() {
        let frame = CGRect(x: 0.1, y: 0.1, width: 0.4, height: 0.2)
        let resized = CanvasSelectionGeometry.resize(
            frame, corner: 0,
            delta: CGPoint(x: -0.1, y: -0.02), preserveAspect: true)
        #expect(abs(resized.width / resized.height - 2) < 0.0001)
        #expect(resized.maxX == frame.maxX)
        #expect(resized.maxY == frame.maxY)
    }

    @Test(arguments: [false, true])
    func layersMoveAndResizeThroughTheCanvasAndUndo(imageLayer: Bool) async throws {
        let root = try StudioTestFiles.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Sample artwork.png")
        try StudioTestFiles.image(url, width: 800, height: 400)
        let editor = StudioImageEditorModel(url: url)
        editor.load()
        defer { editor.close() }
        for _ in 0..<100 {
            if editor.preview != nil { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        #expect(editor.preview != nil)
        if imageLayer {
            let layer = ImageLayer(
                content: .image(path: url.path),
                frame: StudioRect(x: 0.2, y: 0.3, width: 0.4, height: 0.4))
            editor.edit { $0.add(layer) }
            editor.selectLayer(layer.id)
        } else {
            editor.addText(text: "Summer collection")
        }
        let original = try #require(editor.selected)
        let host = NSHostingView(rootView: StudioImageCanvas(editor: editor))
        host.frame = NSRect(x: 0, y: 0, width: 800, height: 500)
        let window = TestWindowHost.window(contentRect: host.frame)
        window.contentView = host
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()
        let image = ImageEditGeometry.fittedRect(
            content: editor.canvasSize,
            in: host.bounds.insetBy(dx: 24, dy: 24))
        let frame = ImageEditGeometry.viewRect(for: original.frame, in: image)
        try await drag(
            host, window: window,
            from: CGPoint(x: frame.midX, y: frame.midY), by: CGSize(width: 50, height: 25))
        let moved = try #require(editor.selected)
        #expect(moved.frame.x > original.frame.x)
        #expect(moved.frame.y > original.frame.y)
        editor.undo()
        #expect(editor.selected?.frame == original.frame)
        host.layoutSubtreeIfNeeded()
        try await drag(
            host, window: window, from: CGPoint(x: frame.maxX, y: frame.maxY),
            by: CGSize(width: 60, height: 30))
        let resized = try #require(editor.selected)
        #expect(resized.frame.width > original.frame.width)
        #expect(resized.frame.height > original.frame.height)
        if imageLayer {
            #expect(abs(resized.frame.width / resized.frame.height - 1) < 0.0001)
        } else if case let .text(before) = original.content,
            case let .text(after) = resized.content
        {
            #expect(after.size > before.size)
        } else {
            Issue.record("Selected layer must remain text")
        }
        editor.undo()
        #expect(editor.selected == original)
    }

    @Test func keyboardManipulationUsesCanvasFocusAndLeavesTextEditingLocal() async throws {
        let root = try StudioTestFiles.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Sample artwork.png")
        try StudioTestFiles.image(url, width: 800, height: 400)
        let editor = StudioImageEditorModel(url: url)
        editor.load()
        defer { editor.close() }
        for _ in 0..<100 {
            if editor.preview != nil { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        editor.addText(text: "Sample caption")
        let original = try #require(editor.selected)
        let host = NSHostingView(rootView: StudioImageCanvas(editor: editor))
        host.frame = NSRect(x: 0, y: 0, width: 800, height: 500)
        let window = TestWindowHost.window(contentRect: host.frame)
        window.contentView = host
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()
        let image = ImageEditGeometry.fittedRect(
            content: editor.canvasSize,
            in: host.bounds.insetBy(dx: 24, dy: 24))
        let frame = ImageEditGeometry.viewRect(for: original.frame, in: image)
        try await drag(host, window: window, from: CGPoint(x: frame.midX, y: frame.midY), by: .zero)
        #expect(window.firstResponder is CanvasPointerView)
        try sendKey(124, characters: "", window: window)
        #expect(
            abs((editor.selected?.frame.x ?? 0) - original.frame.x - 1 / editor.canvasSize.width)
                < 0.00001)
        try sendKey(125, characters: "", modifiers: .shift, window: window)
        #expect(
            abs((editor.selected?.frame.y ?? 0) - original.frame.y - 10 / editor.canvasSize.height)
                < 0.00001)
        try sendKey(6, characters: "z", modifiers: .command, window: window)
        #expect(editor.selected?.frame.y == original.frame.y)
        try sendKey(6, characters: "z", modifiers: .command, window: window)
        #expect(editor.selected == original)
        try sendKey(2, characters: "d", modifiers: .command, window: window)
        #expect(editor.document.layers.count == 2)
        #expect(editor.selected?.id != original.id)
        try sendKey(51, characters: "\u{7F}", window: window)
        #expect(editor.document.layers.count == 1)
        try sendKey(6, characters: "z", modifiers: .command, window: window)
        #expect(editor.document.layers.count == 2)
        editor.selectLayer(original.id)
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        let field = try #require(
            canvasDescendants(host).compactMap { $0 as? NSTextField }.first { $0.isEditable })
        let point = field.convert(CGPoint(x: field.bounds.midX, y: field.bounds.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(
                NSEvent.mouseEvent(
                    with: type, location: point,
                    modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                    clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
            window.sendEvent(event)
        }
        #expect(window.firstResponder is NSTextView)
        let text = try #require(field.currentEditor() as? NSTextView)
        text.selectAll(nil)
        try sendKey(51, characters: "\u{7F}", window: window)
        try await Task.sleep(for: .milliseconds(60))
        #expect(editor.document.layers.count == 2)
        #expect(text.string.isEmpty)
        if case let .text(style) = editor.selected?.content {
            #expect(style.text.isEmpty)
        } else {
            Issue.record("The selected layer must remain a text layer")
        }
        #expect(!TestWindowHost.isExposedOnDesktop(window))
    }

    private func sendKey(
        _ code: UInt16, characters: String,
        modifiers: NSEvent.ModifierFlags = [], window: NSWindow
    ) throws {
        let event = try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero,
                modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
        window.sendEvent(event)
    }

    private func canvasDescendants(_ view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { canvasDescendants($0) }
    }

    @Test func videoOverlaySelectsMovesAndResizesFromEveryCorner() async throws {
        let original = CGRect(x: 0.2, y: 0.3, width: 0.4, height: 0.2)
        let display = CGRect(x: 0, y: 0, width: 800, height: 500)
        var selected = false
        var committed: CGRect?
        let host = NSHostingView(
            rootView: VideoCanvasHandle(
                rect: original, display: display, title: "Sample caption", selected: true,
                select: { selected = true }, commit: { committed = $0 }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .coordinateSpace(name: "videoCanvas"))
        host.frame = display
        let window = TestWindowHost.window(contentRect: display)
        window.contentView = host
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()
        let frame = CGRect(x: 160, y: 150, width: 320, height: 100)
        try await drag(
            host, window: window, from: CGPoint(x: frame.midX, y: frame.midY),
            by: CGSize(width: 40, height: 20))
        #expect(selected)
        #expect(abs((committed?.minX ?? 0) - 0.25) < 0.0001)
        #expect(abs((committed?.minY ?? 0) - 0.34) < 0.0001)
        for corner in 0..<4 {
            committed = nil
            let start = CanvasSelectionGeometry.anchor(corner, in: frame)
            try await drag(
                host, window: window, from: start,
                by: CGSize(width: corner % 2 == 0 ? -40 : 40, height: corner < 2 ? -20 : 20))
            let result = try #require(committed)
            #expect(result.width > original.width)
            #expect(result.height > original.height)
            let fixed = CanvasSelectionGeometry.anchor(3 - corner, in: result)
            let expected = CanvasSelectionGeometry.anchor(3 - corner, in: original)
            #expect(hypot(fixed.x - expected.x, fixed.y - expected.y) < 0.0001)
        }
    }

    @Test func editorRendersWithSelectedTextAtCompactZoomAndBothAppearances() async throws {
        let root = try StudioTestFiles.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Sample artwork.png")
        try StudioTestFiles.image(url, width: 800, height: 400)
        let editor = StudioImageEditorModel(url: url)
        editor.load()
        defer { editor.close() }
        for _ in 0..<100 {
            if editor.preview != nil { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        editor.addText(text: "Summer collection")
        let previous = UIScale.current
        defer { UIScale.apply(previous) }
        for (width, zoom) in [(1280.0, 1.0), (680.0, 1.5)] {
            UIScale.apply(zoom)
            for scheme in [ColorScheme.light, .dark] {
                let host = NSHostingView(
                    rootView:
                        StudioImageEditorView(
                            model: StudioModel(
                                defaults: StudioTestFiles.defaults(), loadsState: false),
                            editor: editor
                        )
                        .environment(\.compactLayout, width < 900)
                        .environment(\.colorScheme, scheme)
                        .environment(\.automaticViewActionsEnabled, false))
                host.frame = NSRect(x: 0, y: 0, width: width, height: 850)
                let window = TestWindowHost.window(contentRect: host.frame)
                window.contentView = host
                window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                window.orderBack(nil)
                defer { window.orderOut(nil) }
                try await Task.sleep(for: .milliseconds(200))
                host.layoutSubtreeIfNeeded()
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let png = try #require(bitmap.representation(using: .png, properties: [:]))
                #expect(png.count > 10_000)
                if let directory = ProcessInfo.processInfo.environment["EDITH_TEST_EVIDENCE_DIR"] {
                    let folder = URL(fileURLWithPath: directory)
                    try FileManager.default.createDirectory(
                        at: folder, withIntermediateDirectories: true)
                    try png.write(
                        to: folder.appendingPathComponent(
                            "studio-selected-text-\(Int(width))-\(scheme).png"))
                }
            }
        }
    }

    private func drag(_ host: NSView, window: NSWindow, from start: CGPoint, by delta: CGSize)
        async throws
    {
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        for (type, fraction) in [
            (NSEvent.EventType.leftMouseDown, 0.0), (.leftMouseDragged, 0.5),
            (.leftMouseDragged, 1.0), (.leftMouseUp, 1.0),
        ] {
            let point = CGPoint(
                x: start.x + delta.width * fraction, y: start.y + delta.height * fraction)
            let event = try #require(
                NSEvent.mouseEvent(
                    with: type,
                    location: host.convert(
                        CGPoint(
                            x: point.x, y: host.isFlipped ? point.y : host.bounds.height - point.y),
                        to: nil),
                    modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                    pressure: type == .leftMouseUp ? 0 : 1))
            NSApp.sendEvent(event)
            try await Task.sleep(for: .milliseconds(30))
            host.layoutSubtreeIfNeeded()
            host.cacheDisplay(in: host.bounds, to: bitmap)
        }
    }
}
