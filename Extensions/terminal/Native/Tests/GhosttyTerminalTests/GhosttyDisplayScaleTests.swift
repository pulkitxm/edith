import AppKit
import GhosttyKit
@testable import GhosttyTerminal
import Testing

@Suite struct GhosttyDisplayScaleTests {
    @Test @MainActor func movingToADisplayWithAnotherScaleRescalesTheRenderLayer() throws {
        _ = TestWindowHost.application
        let view = GhosttyTerminalView(
            externalIO: TestWindowHost.inertIO(),
            theme: GhosttyTheme(
                background: "#111111", foreground: "#eeeeee", cursor: "#eeeeee", fontSize: 13))
        view.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        let window = TestWindowHost.window(contentRect: view.frame)
        window.contentView = view
        defer {
            window.contentView = nil
            view.shutdown()
        }
        let surface = try #require(view.surface)
        let layer = try #require(view.layer)
        let scale = window.backingScaleFactor
        #expect(layer.contentsScale == scale)

        layer.contentsScale = scale == 1 ? 2 : 1
        view.viewDidChangeBackingProperties()

        #expect(layer.contentsScale == scale)
        let size = ghostty_surface_size(surface)
        #expect(CGFloat(size.width_px) == 800 * scale)
        #expect(CGFloat(size.height_px) == 600 * scale)
    }
}
