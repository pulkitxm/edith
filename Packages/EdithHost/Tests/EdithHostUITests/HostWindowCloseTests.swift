import AppKit
import Testing

@testable import EdithHost

@MainActor @Suite(.serialized) struct HostWindowCloseTests {
    private func window(identifier: String? = nil, closable: Bool = true) -> NSWindow {
        let window = TestWindowHost.window(
            contentRect: .init(x: 0, y: 0, width: 200, height: 120),
            styleMask: closable ? [.titled, .closable] : [.titled])
        window.identifier = identifier.map { NSUserInterfaceItemIdentifier($0) }
        return window
    }

    @Test func innermostClosableThingWins() {
        func target(
            main: Bool = false, sheet: Bool = false, popover: Bool = false, closable: Bool = true,
            tab: Bool = false
        ) -> HostWindowCloseTarget {
            HostWindowClose.target(
                isMain: main, sheet: sheet, popover: popover, closable: closable,
                terminalTab: { tab })
        }
        #expect(target(main: true, sheet: true, popover: true, tab: true) == .sheet)
        #expect(target(main: true, popover: true, tab: true) == .popover)
        #expect(target(main: true, tab: true) == .terminalTab)
        #expect(target(main: true) == .nothing)
        #expect(target() == .window)
        #expect(target(closable: false) == .nothing)
    }

    @Test func terminalTabIsOnlyAskedAfterSheetsAndPopoversAreRuledOut() {
        var asked = 0
        _ = HostWindowClose.target(
            isMain: true, sheet: true, popover: false, closable: true,
            terminalTab: { asked += 1; return true })
        #expect(asked == 0)
    }

    @Test func mainWindowNeverClosesAndSwallowsTheKey() {
        let main = window(identifier: HostWindowClose.mainIdentifier)
        defer { main.close() }
        main.orderBack(nil)
        #expect(HostWindowClose.perform(window: main))
        #expect(HostWindowClose.perform(window: main, terminalTab: { true }))
        #expect(HostWindowClose.isMain(main))
        #expect(NSApp.windows.contains(main))
    }

    @Test func detachedWindowsCloseThemselvesAndOthersAreLeftToTheSystem() {
        let detached = window(identifier: "EdithSection.home")
        var closed = 0
        let observer = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: detached, queue: nil
        ) { _ in closed += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }
        detached.orderBack(nil)
        #expect(HostWindowClose.perform(window: detached))
        #expect(closed == 1)
        let fixed = window(identifier: "Other", closable: false)
        defer { fixed.close() }
        #expect(!HostWindowClose.perform(window: fixed))
        #expect(!HostWindowClose.perform(window: nil))
    }

    @Test func sheetsReceiveEscapeInsteadOfClosingTheirParent() {
        let parent = window(identifier: HostWindowClose.mainIdentifier)
        let sheet = window()
        defer { parent.close(); sheet.close() }
        var dismissed: [NSWindow] = []
        parent.beginSheet(sheet, completionHandler: nil)
        #expect(HostWindowClose.attachedSheet(of: parent) === sheet)
        #expect(HostWindowClose.attachedSheet(of: sheet) === sheet)
        let fromParent = HostWindowClose.perform(window: parent, dismiss: { dismissed.append($0) })
        let fromSheet = HostWindowClose.perform(window: sheet, dismiss: { dismissed.append($0) })
        #expect(fromParent && fromSheet)
        #expect(dismissed == [sheet, sheet])
        parent.endSheet(sheet)
    }

    @Test func hidingTheMainWindowKeepsItAliveAndOffscreen() {
        let main = window(identifier: HostWindowClose.mainIdentifier)
        defer { main.close(); NSApp.setActivationPolicy(.prohibited) }
        main.orderBack(nil)
        HostMainWindowHider.hide(main)
        #expect(!main.isVisible)
        #expect(NSApp.windows.contains(main))
    }

    @Test func accessoryDropRequiresNoVisiblePresentingWindow() {
        let hidden = window()
        #expect(!HostApplicationDelegate.isPresenting([hidden]))
        let panel = NSPanel(
            contentRect: .init(x: 0, y: 0, width: 10, height: 10), styleMask: [.titled],
            backing: .buffered, defer: true)
        #expect(!HostApplicationDelegate.isPresenting([panel]))
        #expect(!HostApplicationDelegate.isPresenting([]))
    }
}
