import AppKit
import Testing

@testable import EdithHost

@Suite @MainActor struct HostApplicationPresenceTests {
    @Test func reopeningAWindowlessAppOpensTheMainWindow() {
        let delegate = HostApplicationDelegate()
        var opened = 0
        var activated = 0
        delegate.mainWindow = { nil }
        delegate.openMainWindow = { opened += 1 }
        delegate.activate = { activated += 1 }
        #expect(
            !delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: false))
        #expect(opened == 1 && activated == 1)
    }

    @Test func reopeningBeforeTheMainWindowExistsDefersToTheSystemInsteadOfRelaunching() {
        let delegate = HostApplicationDelegate()
        var activated = 0
        delegate.mainWindow = { nil }
        delegate.activate = { activated += 1 }
        #expect(
            delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: false))
        #expect(activated == 0)
        delegate.showMainWindow()
        #expect(activated == 1)
    }

    @Test func panelsAndBorderlessOverlaysNeverPresentTheApplication() {
        let panel = NSPanel(
            contentRect: .init(x: 0, y: 0, width: 10, height: 10),
            styleMask: [.titled], backing: .buffered, defer: true)
        let borderless = NSWindow(
            contentRect: .init(x: 0, y: 0, width: 10, height: 10),
            styleMask: [.borderless], backing: .buffered, defer: true)
        #expect(!HostApplicationDelegate.presentsApplication(panel))
        #expect(!HostApplicationDelegate.presentsApplication(borderless))
    }
}
