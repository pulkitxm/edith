import AppKit
import SwiftUI
import Testing

@MainActor @Suite(.serialized) struct TestWindowHostTests {
    @Test func testHostNeverRegistersAsALaunchedApplication() {
        #expect(TestWindowHost.application.activationPolicy() == .prohibited)
        #expect(!TestWindowHost.application.isActive)
    }

    @Test func hostedWindowsStayOffEveryScreenWhileRendering() throws {
        let host = NSHostingView(rootView: Color.blue.frame(width: 320, height: 200))
        host.frame = NSRect(x: 0, y: 0, width: 320, height: 200)
        let window = TestWindowHost.window(contentRect: host.frame)
        defer { window.orderOut(nil) }
        window.contentView = host
        window.orderBack(nil)
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()

        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)

        #expect(bitmap.pixelsWide >= 320)
        #expect(!TestWindowHost.isExposedOnDesktop(window))
        #expect(window.collectionBehavior.contains(.transient))
        #expect(window.isExcludedFromWindowsMenu)
        #expect(TestWindowHost.exposedWindows.isEmpty)
    }

    @Test func titledWindowsAreNotPulledBackOntoAScreen() {
        let window = TestWindowHost.window(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
            styleMask: [.titled, .resizable])
        defer { window.orderOut(nil) }
        window.orderBack(nil)

        #expect(!TestWindowHost.isExposedOnDesktop(window))
    }
}
