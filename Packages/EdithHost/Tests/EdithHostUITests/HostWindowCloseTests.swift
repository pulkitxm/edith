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

    private func attach(_ sheet: NSWindow, to parent: NSWindow) {
        let root = HostWindowClose.owner(of: parent) ?? parent
        let origins = [root, parent].map { ($0, $0.frame.origin) }
        parent.alphaValue = 0
        sheet.alphaValue = 0
        parent.beginSheet(sheet, completionHandler: nil)
        for (window, origin) in origins { window.setFrameOrigin(origin) }
        sheet.setFrameOrigin(parent.frame.origin)
        #expect(!TestWindowHost.isExposedOnDesktop(parent))
        #expect(!TestWindowHost.isExposedOnDesktop(sheet))
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
        #expect(target(main: true, sheet: true, popover: true, tab: true) == .popover)
        #expect(target(main: true, sheet: true, tab: true) == .sheet)
        #expect(target(main: true, popover: true, tab: true) == .popover)
        #expect(target(main: true, tab: true) == .terminalTab)
        #expect(target(main: true) == .nothing)
        #expect(target(tab: true) == .terminalTab)
        #expect(target() == .window)
        #expect(target(closable: false) == .nothing)
    }

    @Test func terminalTabIsOnlyAskedAfterSheetsAndPopoversAreRuledOut() {
        var asked = 0
        _ = HostWindowClose.target(
            isMain: true, sheet: true, popover: false, closable: true,
            terminalTab: { asked += 1; return true })
        _ = HostWindowClose.target(
            isMain: true, sheet: false, popover: true, closable: true,
            terminalTab: { asked += 1; return true })
        #expect(asked == 0)
    }

    @Test func keyMonitorRoutesOnlyEdithWindowsAndTheirSheetsAndPopovers() {
        let main = window(identifier: HostWindowClose.mainIdentifier)
        let section = window(identifier: "EdithSection.terminal.window.synthetic")
        let foreign = window(identifier: "Other")
        let mainSheet = window()
        let sectionSheet = window()
        let popover = SyntheticPopoverWindow(
            contentRect: .init(x: 0, y: 0, width: 80, height: 60), styleMask: [.borderless],
            backing: .buffered, defer: true)
        popover.isReleasedWhenClosed = false
        defer {
            main.endSheet(mainSheet); section.endSheet(sectionSheet)
            main.removeChildWindow(popover)
            for window in [main, section, foreign, mainSheet, sectionSheet, popover] {
                window.close()
            }
        }
        main.orderBack(nil); section.orderBack(nil)
        attach(mainSheet, to: main)
        attach(sectionSheet, to: section)
        popover.setFrameOrigin(main.frame.origin)
        main.addChildWindow(popover, ordered: .above)
        let isSection: (NSWindow) -> Bool = { $0 === section }
        #expect(HostWindowClose.route(keyWindow: main, isSection: isSection) == .main)
        #expect(HostWindowClose.route(keyWindow: mainSheet, isSection: isSection) == .main)
        #expect(HostWindowClose.route(keyWindow: popover, isSection: isSection) == .main)
        #expect(HostWindowClose.route(keyWindow: section, isSection: isSection) == .section)
        #expect(HostWindowClose.route(keyWindow: sectionSheet, isSection: isSection) == .section)
        #expect(HostWindowClose.route(keyWindow: foreign, isSection: isSection) == nil)
        #expect(HostWindowClose.route(keyWindow: nil, isSection: isSection) == nil)
        #expect(HostWindowClose.owner(of: popover) === main)
        #expect(HostWindowClose.owner(of: sectionSheet) === section)
    }

    @Test func popoversCloseBeforeTheirSheetOrWindow() {
        let main = window(identifier: HostWindowClose.mainIdentifier)
        let sheet = window()
        let popover = SyntheticPopoverWindow(
            contentRect: .init(x: 0, y: 0, width: 80, height: 60), styleMask: [.borderless],
            backing: .buffered, defer: true)
        popover.isReleasedWhenClosed = false
        defer { main.endSheet(sheet); main.close(); sheet.close(); popover.close() }
        main.orderBack(nil)
        attach(sheet, to: main)
        popover.setFrameOrigin(main.frame.origin)
        sheet.addChildWindow(popover, ordered: .above)
        var dismissed: [NSWindow] = []
        let closed1 = HostWindowClose.perform(window: sheet, dismiss: { dismissed.append($0) })
        #expect(closed1)
        let closed2 = HostWindowClose.perform(window: popover, dismiss: { dismissed.append($0) })
        #expect(closed2)
        let closed3 = HostWindowClose.perform(window: main, dismiss: { dismissed.append($0) })
        #expect(closed3)
        #expect(dismissed == [popover, popover, popover])
        sheet.removeChildWindow(popover)
        popover.orderOut(nil)
        let closed4 = HostWindowClose.perform(window: main, dismiss: { dismissed.append($0) })
        #expect(closed4)
        #expect(dismissed.last === sheet)
        #expect(main.isVisible)
        #expect(TestWindowHost.exposedWindows.isEmpty)
    }

    @Test func nestedSheetsDismissTheInnermostFirst() {
        let section = window(identifier: "EdithSection.home")
        let outer = window()
        let inner = window()
        defer {
            outer.endSheet(inner); section.endSheet(outer)
            section.close(); outer.close(); inner.close()
        }
        section.orderBack(nil)
        attach(outer, to: section)
        attach(inner, to: outer)
        var dismissed: [NSWindow] = []
        var closed = 0
        let observer = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: section, queue: nil
        ) { _ in closed += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }
        let closed5 = HostWindowClose.perform(window: section, dismiss: { dismissed.append($0) })
        #expect(closed5)
        let closed6 = HostWindowClose.perform(window: outer, dismiss: { dismissed.append($0) })
        #expect(closed6)
        #expect(dismissed == [inner, inner])
        #expect(closed == 0)
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
        attach(sheet, to: parent)
        #expect(HostWindowClose.innermostSheet(of: parent) === sheet)
        #expect(HostWindowClose.innermostSheet(of: sheet) === sheet)
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

private final class SyntheticPopoverWindow: NSWindow {}
