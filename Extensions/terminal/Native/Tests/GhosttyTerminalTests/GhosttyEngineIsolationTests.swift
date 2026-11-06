import AppKit
@testable import GhosttyTerminal
import ObjectiveC
import Testing

@Suite struct GhosttyEngineIsolationTests {
    @Test @MainActor func anotherEngineCopyOwningTheSharedLayerNameDoesNotBlockRendering() throws {
        _ = TestWindowHost.application
        if let foreign = objc_allocateClassPair(CALayer.self, "IOSurfaceLayer", 0) {
            objc_registerClassPair(foreign)
        }
        let view = GhosttyTerminalView(externalIO: TestWindowHost.inertIO())
        view.frame = NSRect(x: 0, y: 0, width: 640, height: 400)
        let window = TestWindowHost.window(contentRect: view.frame)
        window.contentView = view
        defer {
            window.contentView = nil
            view.shutdown()
        }
        _ = try #require(view.surface)
        let layer = try #require(view.layer)
        let name = String(cString: class_getName(type(of: layer)))
        #expect(name.hasPrefix("IOSurfaceLayer_"))
        #expect(name != "IOSurfaceLayer")
    }
}
