import AppKit
import GhosttyKit
@testable import GhosttyTerminal
import IOSurface
import RendererAudit
import Testing

@Suite(.serialized) @MainActor struct GhosttyExternalIOTests {
    @Test func rawSplitVTAndUTF8RenderNativePixelsAndReplyThroughCallbacks() async throws {
        var writes = Data()
        var sizes: [(UInt16, UInt16)] = []
        var failed = false
        #expect(renderer_audit_probe())
        renderer_audit_begin()
        defer { renderer_audit_end() }
        let io = GhosttyExternalIO(
            write: { writes.append($0) },
            resize: { columns, rows, _, _ in
                sizes.append((columns, rows))
            }, failure: { failed = true })
        let window = TestWindowHost.window(contentRect: NSRect(x: 0, y: 0, width: 640, height: 400))
        let view = GhosttyTerminalView(externalIO: io)
        defer { view.shutdown(); window.contentView = nil }
        view.frame = window.contentLayoutRect
        window.contentView = view
        let surface = try #require(view.surface)
        let output = Data(
            "\u{1b}[2J\u{1b}[H\u{1b}[38;2;0;255;0mVT-state ☃\u{1b}[0m\u{1b}[3;4H\u{1b}[6n".utf8)
        for byte in output { #expect(view.receiveOutput(Data([byte]))) }
        for _ in 0..<30 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(writes == Data("\u{1b}[3;4R".utf8))
        #expect(!sizes.isEmpty && sizes.last?.0 == ghostty_surface_size(surface).columns)
        ghostty_surface_set_occlusion(surface, true)
        var green = 0
        for _ in 0..<100 {
            ghostty_surface_draw(surface)
            if let contents = view.layer?.contents as AnyObject?,
                CFGetTypeID(contents) == IOSurfaceGetTypeID()
            {
                let frame = unsafeBitCast(contents, to: IOSurfaceRef.self)
                #expect(IOSurfaceLock(frame, .readOnly, nil) == 0)
                let pixels = IOSurfaceGetBaseAddress(frame).assumingMemoryBound(to: UInt8.self)
                let stride = IOSurfaceGetBytesPerRow(frame)
                green = 0
                for row in 0..<IOSurfaceGetHeight(frame) {
                    for column in 0..<IOSurfaceGetWidth(frame) {
                        let pixel = pixels + row * stride + column * 4
                        if Int(pixel[1]) > Int(pixel[0]) + 20 && Int(pixel[1]) > Int(pixel[2]) + 20
                        {
                            green += 1
                        }
                    }
                }
                IOSurfaceUnlock(frame, .readOnly, nil)
            }
            if green > 10 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(green > 10)
        #expect(view.performBindingAction("select_all"))
        #expect(view.selectedText()?.contains("VT-state ☃") == true)

        writes.removeAll()
        #expect(view.insertText("user-bytes"))
        for _ in 0..<30 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(writes == Data("user-bytes".utf8))
        #expect(view.selectedText()?.contains("user-bytes") == false)
        #expect(!NSApp.isActive)
        #expect(view.setTermios(canonical: true, echo: false))
        #expect(view.secureInputRequested)
        #expect(view.setTermios(canonical: false, echo: false))
        #expect(!view.secureInputRequested)
        #expect(view.setTermios(canonical: true, echo: false))
        #expect(view.secureInputRequested)
        #expect(view.processExited(9))
        #expect(!view.secureInputRequested)
        let count = sizes.count
        _ = view.insertText("ignored")
        view.setFrameSize(NSSize(width: 800, height: 600))
        for _ in 0..<30 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(writes == Data("user-bytes".utf8) && sizes.count == count && !failed)
        #expect(!view.receiveOutput(Data("stale".utf8)))
        view.shutdown()
        #expect(renderer_audit_process_calls() == 0 && renderer_audit_pty_calls() == 0)
        #expect(TestWindowHost.exposedWindows.isEmpty)
    }

    @Test func callbacksCopyBeforeReturnAndInvalidationDropsQueuedWork() async throws {
        var delivered = Data()
        var failures = 0
        let io = GhosttyExternalIO(
            write: { delivered.append($0) }, resize: { _, _, _, _ in }, failure: { failures += 1 })
        var bytes: [UInt8] = [1, 2, 3]
        bytes.withUnsafeBufferPointer { io.enqueue(bytes: $0.baseAddress, count: $0.count) }
        bytes = [4, 5, 6]
        for _ in 0..<5 { await Task.yield() }
        #expect(delivered == Data([1, 2, 3]))
        bytes.withUnsafeBufferPointer { io.enqueue(bytes: $0.baseAddress, count: $0.count) }
        io.invalidate()
        for _ in 0..<5 { await Task.yield() }
        #expect(delivered == Data([1, 2, 3]) && failures == 0)
    }

    @Test func boundedCallbackQueueFailsClosed() async {
        var delivered = 0
        var failed = 0
        let io = GhosttyExternalIO(
            write: { delivered += $0.count }, resize: { _, _, _, _ in }, failure: { failed += 1 })
        let bytes = [UInt8](repeating: 1, count: 16_384)
        for _ in 0..<17 {
            bytes.withUnsafeBufferPointer { io.enqueue(bytes: $0.baseAddress, count: $0.count) }
        }
        for _ in 0..<10 { await Task.yield() }
        #expect(delivered == 0 && failed == 1)
    }
    @Test func originalPaneBindingsAndFontZoomStayNativeWithoutNewProcesses() async throws {
        #expect(renderer_audit_probe())
        renderer_audit_begin()
        defer { renderer_audit_end() }
        var actions: [GhosttyPaneAction] = []
        let window = TestWindowHost.window(contentRect: NSRect(x: 0, y: 0, width: 640, height: 400))
        var io: GhosttyExternalIO? = TestWindowHost.inertIO()
        weak var releasedIO = io
        let view = GhosttyTerminalView(externalIO: try #require(io))
        io = nil
        view.onPaneAction = { actions.append($0) }
        view.frame = window.contentLayoutRect
        window.contentView = view
        defer { view.shutdown(); window.contentView = nil }
        let surface = try #require(view.surface)
        let before = ghostty_surface_size(surface)
        #expect(view.fontZoom(.increase))
        try await Task.sleep(for: .milliseconds(100))
        let enlarged = ghostty_surface_size(surface)
        #expect(enlarged.cell_height_px > before.cell_height_px)
        #expect(view.fontZoom(.reset))
        try await Task.sleep(for: .milliseconds(100))
        #expect(ghostty_surface_size(surface).cell_height_px == before.cell_height_px)
        #expect(view.performBindingAction("new_split:right"))
        #expect(view.performBindingAction("goto_split:next"))
        for _ in 0..<10 { await Task.yield() }
        #expect(actions == [.split(.right), .focus(.next)])
        view.setHostWindowState(active: false, key: true)
        #expect(!view.owningApplicationActive && view.owningWindowKey)
        _ = view.performBindingAction("new_split:down")
        view.shutdown()
        for _ in 0..<10 { await Task.yield() }
        #expect(actions == [.split(.right), .focus(.next)])
        #expect(releasedIO == nil)
        #expect(renderer_audit_process_calls() == 0 && renderer_audit_pty_calls() == 0)
        #expect(TestWindowHost.exposedWindows.isEmpty)
    }

}
