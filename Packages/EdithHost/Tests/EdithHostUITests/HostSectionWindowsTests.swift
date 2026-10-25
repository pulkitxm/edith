import AppKit
import SwiftUI
import Testing

@testable import EdithHost

@Suite struct HostWindowTabCommandTests {
    @Test func originalTabChordsOnlyClaimActualNativeGroups() {
        for tabbed in [false, true] {
            #expect(
                HostWindowTabCommand.resolve(
                    characters: "\t", keyCode: 48, modifiers: .control, tabbed: tabbed)
                    == (tabbed ? .next : nil))
            #expect(
                HostWindowTabCommand.resolve(
                    characters: "\t", keyCode: 48, modifiers: [.control, .shift], tabbed: tabbed)
                    == (tabbed ? .previous : nil))
            for number in 1...9 {
                #expect(
                    HostWindowTabCommand.resolve(
                        characters: String(number), keyCode: 0, modifiers: [.command, .capsLock],
                        tabbed: tabbed) == (tabbed ? .select(number - 1) : nil))
            }
        }
        for modifiers: NSEvent.ModifierFlags in [.command, [.control, .command], .option, []] {
            #expect(
                HostWindowTabCommand.resolve(
                    characters: "\t", keyCode: 48, modifiers: modifiers, tabbed: true) == nil)
        }
        for characters in ["0", "10", "x"] {
            #expect(
                HostWindowTabCommand.resolve(
                    characters: characters, keyCode: 0, modifiers: .command, tabbed: true) == nil)
        }
        #expect(
            HostWindowTabCommand.resolve(
                characters: "1", keyCode: 0, modifiers: [.command, .option], tabbed: true) == nil)
    }
}

@MainActor
@Suite(.serialized) struct HostSectionWindowsTests {
    @Test func explicitSectionWindowsReuseFocusAndRestoreOriginalNativeChrome() throws {
        _ = TestWindowHost.application
        var shown: [NSWindow] = []
        var constructed: [String] = []
        let sections = HostSectionWindows(
            saveFrames: false,
            makeWindow: {
                TestWindowHost.window(
                    contentRect: $0, styleMask: [.titled, .closable, .resizable, .miniaturizable])
            },
            present: {
                shown.append($0); $0.orderBack(nil)
            },
            visibleFrame: { NSRect(x: 0, y: 0, width: 1440, height: 900) }
        ) { page in
            constructed.append(page.id)
            return AnyView(Text("Synthetic " + page.title))
        }
        defer { sections.closeAll() }
        let first = try #require(sections.open("home"))
        #expect(first.contentMinSize == NSSize(width: 560, height: 420))
        #expect(first.contentView?.frame.size == NSSize(width: 880, height: 640))
        #expect(first.title == "Home")
        #expect(first.tabbingMode == .automatic)
        #expect(first.tabbingIdentifier == "EdithSection")
        #expect(first.identifier?.rawValue == "EdithSection.home")
        #expect(!first.isRestorable)
        #expect(sections.contains(first))
        #expect(!TestWindowHost.isExposedOnDesktop(first))
        #expect(sections.open("home") === first)
        #expect(constructed == ["home"])
        #expect(sections.focusExisting("home"))
        #expect(!sections.focusExisting("unknown"))
        let second = try #require(sections.open("extensions", mode: .alwaysNew))
        #expect(HostSectionWindows.tabbedWindows(first).isEmpty)
        #expect(HostSectionWindows.tabbedWindows(second).isEmpty)
        #expect(sections.openDestinations == ["extensions", "home"])
        sections.windowDidBecomeKey(
            Notification(name: NSWindow.didBecomeKeyNotification, object: first))
        #expect(sections.openDestinations == ["home", "extensions"])
        #expect(sections.open("about") == nil)
        #expect(sections.open("foreign") == nil)
        second.close()
        #expect(sections.openDestinations == ["home"])
        #expect(!sections.contains(second))
        #expect(shown.allSatisfy { !TestWindowHost.isExposedOnDesktop($0) })
    }

    @Test func actualNativeTabSelectionCyclesAndHintsRestoreCleanTitles() throws {
        _ = TestWindowHost.application
        var shown: [NSWindow] = []
        let sections = HostSectionWindows(
            saveFrames: false,
            makeWindow: {
                TestWindowHost.window(
                    contentRect: $0, styleMask: [.titled, .closable, .resizable, .miniaturizable])
            },
            present: {
                shown.append($0); $0.orderBack(nil)
            }
        ) { AnyView(Text("Synthetic " + $0.title)) }
        defer { sections.closeAll() }
        let first = try #require(sections.open("home"))
        let second = try #require(sections.open("extensions"))
        let tabs = HostSectionWindows.tabbedWindows(first)
        #expect(tabs.count == 2)
        let firstIndex = try #require(tabs.firstIndex(of: first))
        let next = tabs[(firstIndex + 1) % tabs.count]
        #expect(sections.perform(.next, in: first))
        #expect(shown.last === next)
        #expect(sections.perform(.previous, in: next))
        #expect(shown.last === first)
        #expect(sections.perform(.select(1), in: first))
        #expect(shown.last === tabs[1])
        let count = shown.count
        #expect(!sections.perform(.select(9), in: first))
        #expect(shown.count == count)
        let titles = tabs.map(\.title)
        sections.showHints(true, in: first)
        #expect(tabs[0].title == "⌘1  " + titles[0])
        #expect(tabs[1].title == "⌘2  " + titles[1])
        sections.showHints(true, in: second)
        #expect(tabs[0].title == "⌘1  " + titles[0])
        sections.showHints(false, in: second)
        #expect(tabs.map(\.title) == titles)
        #expect(tabs.allSatisfy { !TestWindowHost.isExposedOnDesktop($0) })
    }

    @Test func windowMenuHasRealSectionActionsAndIsIdempotent() throws {
        _ = TestWindowHost.application
        let sections = HostSectionWindows(
            saveFrames: false,
            makeWindow: {
                TestWindowHost.window(
                    contentRect: $0, styleMask: [.titled, .closable, .resizable, .miniaturizable])
            },
            present: { $0.orderBack(nil) }
        ) { AnyView(Text("Synthetic " + $0.title)) }
        defer { sections.closeAll() }
        let menu = NSMenu(title: "Synthetic Window")
        sections.populate(menu)
        let count = menu.items.count
        sections.populate(menu)
        #expect(menu.items.count == count)
        #expect(menu.items[0].title == "Show Next Tab")
        #expect(menu.items[0].keyEquivalentModifierMask == .control)
        #expect(menu.items[1].keyEquivalentModifierMask == [.control, .shift])
        #expect(!menu.items.contains { $0.title == "Open About in New Window" })
        let home = try #require(menu.items.firstIndex { $0.title == "Open Home in New Window" })
        #expect(sections.validateMenuItem(menu.items[home]))
        menu.performActionForItem(at: home)
        #expect(sections.openDestinations == ["home"])
        let settings = try #require(
            menu.items.firstIndex { $0.title == "Open Settings in New Window" })
        menu.performActionForItem(at: settings)
        #expect(sections.openDestinations == ["settings", "home"])
        #expect(
            !sections.validateMenuItem(NSMenuItem(title: "Foreign", action: nil, keyEquivalent: ""))
        )
        sections.closeAll()
        #expect(sections.openDestinations.isEmpty)
    }

    @Test func detachedSizeFitsSmallDisplaysWithoutChangingOriginalMinimums() throws {
        _ = TestWindowHost.application
        let sections = HostSectionWindows(
            saveFrames: false,
            makeWindow: {
                TestWindowHost.window(
                    contentRect: $0, styleMask: [.titled, .closable, .resizable, .miniaturizable])
            },
            present: { _ in }, visibleFrame: { NSRect(x: 0, y: 0, width: 500, height: 300) }
        ) { AnyView(Text("Synthetic " + $0.title)) }
        defer { sections.closeAll() }
        let window = try #require(sections.open("home"))
        #expect(window.contentMinSize == NSSize(width: 500, height: 300))
        #expect(window.contentView?.frame.size == NSSize(width: 500, height: 300))
        #expect(!TestWindowHost.isExposedOnDesktop(window))
    }
}
