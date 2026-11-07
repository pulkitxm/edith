import AppKit
import SwiftUI
import Testing
@testable import EdithExtensionUI

private final class MenuOwningView: NSView {
    override func menu(for event: NSEvent) -> NSMenu? { NSMenu(title: "Embedded") }
}

private struct MenuOwningRegion: NSViewRepresentable {
    func makeNSView(context: Context) -> MenuOwningView { MenuOwningView() }
    func updateNSView(_ view: MenuOwningView, context: Context) {}
}

@MainActor
private final class MenuProbe {
    var calls: [String] = []
    var label = "First"
}

@MainActor
@Suite(.serialized)
struct EdithMenuTests {
    init() { _ = NSApplication.shared }

    @Test func normalizingDropsLeadingTrailingAndRepeatedSeparatorsAndEmptySubmenus() {
        let items = EdithMenu.items {
            EdithMenuItem.separator
            EdithMenuItem.button("One") {}
            EdithMenuItem.separator
            EdithMenuItem.separator
            EdithMenuItem.menu("Empty") {
                EdithMenuItem.separator
            }
            EdithMenuItem.separator
            EdithMenuItem.menu("Nested") {
                EdithMenuItem.separator
                EdithMenuItem.button("Two") {}
                EdithMenuItem.separator
            }
            EdithMenuItem.separator
        }

        let menu = EdithMenu.makeMenu(items)

        #expect(menu.items.map(\.title) == ["One", "", "Nested"])
        #expect(menu.items[1].isSeparatorItem)
        #expect(menu.items[2].submenu?.items.map(\.title) == ["Two"])
        assertNoStraySeparators(menu)
    }

    @Test func builtMenuKeepsEnablementTooltipsAndRunsActions() throws {
        let probe = MenuProbe()
        let items = EdithMenu.items {
            EdithMenuItem.button("Run", help: "Runs it") { probe.calls.append("run") }
            EdithMenuItem.button("Blocked", enabled: false) { probe.calls.append("blocked") }
            EdithMenuItem.menu("More") {
                EdithMenuItem.button("Inner") { probe.calls.append("inner") }
            }
            EdithMenuItem.menu("Off") {
                EdithMenuItem.button("Hidden") {}
            }
            .disabled(true)
        }

        let menu = EdithMenu.makeMenu(items)

        #expect(menu.autoenablesItems == false)
        #expect(menu.items.map(\.isEnabled) == [true, false, true, false])
        #expect(menu.items[0].toolTip == "Runs it")
        menu.performActionForItem(at: 0)
        let submenu = try #require(menu.items[2].submenu)
        #expect(submenu.autoenablesItems == false)
        submenu.performActionForItem(at: 0)
        #expect(probe.calls == ["run", "inner"])
    }

    @Test func contextMenuIsBuiltOnOpenAndUnaffectedByLaterUpdates() throws {
        let probe = MenuProbe()
        let host = NSHostingView(rootView: probeView(probe))
        let window = makeWindow(host)
        defer { window.close() }
        let region = try #require(find(EdithContextMenuView.self, in: host))
        let open = try #require(rightClick(window))

        let menu = try #require(region.menu(for: open))
        for index in 0..<50 {
            probe.label = "Update \(index)"
            host.rootView = probeView(probe)
            host.layoutSubtreeIfNeeded()
        }

        #expect(menu.items.map(\.title) == ["First", "", "More"])
        #expect(menu.items.filter { !$0.isSeparatorItem }.map(\.isEnabled) == [true, true])
        #expect(menu.items[2].submenu?.items.map(\.title) == ["Nested"])
        menu.performActionForItem(at: 0)
        #expect(probe.calls == ["First"])
        let current = try #require(find(EdithContextMenuView.self, in: host))
        let reopened = try #require(current.menu(for: open))
        #expect(reopened.items.first?.title == "Update 49")
    }

    @Test func rightClicksReachTheRegionAndOtherClicksPassThrough() throws {
        let probe = MenuProbe()
        let host = NSHostingView(rootView: probeView(probe))
        let window = makeWindow(host)
        defer { window.close() }
        let region = try #require(find(EdithContextMenuView.self, in: host))
        let point = NSPoint(x: 50, y: 50)

        region.currentEvent = { [weak window] in window.flatMap { rightClick($0) } }
        #expect(host.hitTest(point) === region)
        region.currentEvent = { [weak window] in
            window.flatMap { mouse($0, .leftMouseDown, flags: .control) }
        }
        #expect(host.hitTest(point) === region)
        region.currentEvent = { [weak window] in window.flatMap { mouse($0, .leftMouseDown) } }
        #expect(host.hitTest(point) !== region)
        region.currentEvent = { [weak window] in window.flatMap { mouse($0, .mouseMoved) } }
        #expect(host.hitTest(point) !== region)
    }

    @Test func embeddedViewsWithTheirOwnMenuKeepTheirRightClicks() throws {
        let host = NSHostingView(
            rootView: MenuOwningRegion()
                .frame(width: 100, height: 100)
                .edithContextMenu { [EdithMenuItem.button("Outer") {}] }
        )
        let window = makeWindow(host)
        defer { window.close() }
        let region = try #require(find(EdithContextMenuView.self, in: host))
        region.currentEvent = { [weak window] in window.flatMap { rightClick($0) } }

        let hit = host.hitTest(NSPoint(x: 50, y: 50))

        #expect(hit !== region)
        #expect(hit.map { $0.isDescendant(of: host) } == true)
    }

    private func probeView(_ probe: MenuProbe) -> some View {
        let label = probe.label
        return Color.clear
            .frame(width: 100, height: 100)
            .edithContextMenu {
                EdithMenu.items {
                    EdithMenuItem.separator
                    EdithMenuItem.button(label) { probe.calls.append(label) }
                    EdithMenuItem.separator
                    EdithMenuItem.menu("More") {
                        EdithMenuItem.button("Nested") {}
                    }
                }
            }
    }

    private func makeWindow(_ host: NSView) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.borderless],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 100, height: 100)
        host.layoutSubtreeIfNeeded()
        return window
    }

    private func find<T: NSView>(_ type: T.Type, in root: NSView) -> T? {
        if let match = root as? T { return match }
        for child in root.subviews {
            if let match = find(type, in: child) { return match }
        }
        return nil
    }

    private func assertNoStraySeparators(_ menu: NSMenu) {
        let items = menu.items
        #expect(items.first?.isSeparatorItem != true)
        #expect(items.last?.isSeparatorItem != true)
        for (left, right) in zip(items, items.dropFirst()) {
            #expect(!(left.isSeparatorItem && right.isSeparatorItem))
        }
        for item in items { if let submenu = item.submenu { assertNoStraySeparators(submenu) } }
    }
}

@MainActor
private func rightClick(_ window: NSWindow) -> NSEvent? {
    mouse(window, .rightMouseDown)
}

@MainActor
private func mouse(
    _ window: NSWindow, _ type: NSEvent.EventType, flags: NSEvent.ModifierFlags = []
) -> NSEvent? {
    NSEvent.mouseEvent(
        with: type, location: NSPoint(x: 50, y: 50), modifierFlags: flags, timestamp: 0,
        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
        pressure: 1)
}
