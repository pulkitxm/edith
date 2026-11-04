import AppKit
import EdithExtensionUI
import SwiftUI
import Testing

@testable import EdithHost

private struct VisibilityProbe: View {
    final class Box { var visible: Bool? }
    let box: Box
    @Environment(\.windowVisible) private var visible

    var body: some View {
        box.visible = visible
        return Color.clear
    }
}

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

    @Test func backgroundTestingReportsOccludedWindowsAsVisible() {
        #expect(observedVisibility(backgroundTesting: true) == true)
        #expect(observedVisibility(backgroundTesting: false) == false)
    }

    private func observedVisibility(backgroundTesting: Bool) -> Bool? {
        let probe = VisibilityProbe.Box()
        let host = NSHostingView(
            rootView: VisibilityProbe(box: probe)
                .modifier(HostBackgroundTestingVisibility(enabled: backgroundTesting))
                .environment(\.windowVisible, false))
        host.frame = NSRect(x: 0, y: 0, width: 40, height: 40)
        host.layoutSubtreeIfNeeded()
        return probe.visible
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
