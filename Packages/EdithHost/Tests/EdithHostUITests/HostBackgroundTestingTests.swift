import AppKit
import Testing

@testable import EdithHost

@MainActor
@Suite struct HostBackgroundTestingTests {
    @Test func acceptsOnlyDevelopmentBuildsWithTheFlag() {
        let flag = ["EDITH_BACKGROUND_TESTING": "1"]
        #expect(
            HostBackgroundTesting.accepts(
                environment: flag, bundleIdentifier: "com.pulkit.edith.dev.main"))
        #expect(
            !HostBackgroundTesting.accepts(environment: flag, bundleIdentifier: "com.pulkit.edith"))
        #expect(
            !HostBackgroundTesting.accepts(
                environment: [:], bundleIdentifier: "com.pulkit.edith.dev.main"))
        #expect(
            !HostBackgroundTesting.accepts(
                environment: ["EDITH_BACKGROUND_TESTING": "0"],
                bundleIdentifier: "com.pulkit.edith.dev.main"))
    }

    @Test func presentKeepsWindowsInvisibleWithoutKeyStatus() {
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 200, height: 120),
            styleMask: [.titled], backing: .buffered, defer: true)
        HostBackgroundTesting.present(window)
        #expect(window.alphaValue == 0)
        #expect(window.ignoresMouseEvents)
        #expect(window.isVisible)
        #expect(!window.isKeyWindow)
        window.orderOut(nil)
    }

    @Test func leavesPanelsInPlace() {
        let panel = NSPanel(
            contentRect: NSRect(x: 40, y: 40, width: 50, height: 50), styleMask: [],
            backing: .buffered, defer: true)
        HostBackgroundTesting.hide(panel)
        #expect(panel.alphaValue == 1)
        #expect(!panel.ignoresMouseEvents)
    }
}
