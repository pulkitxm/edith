import AppKit
import EdithKit
import SwiftUI
import Testing
@testable import Edith
@testable import EdithMenuBar

@MainActor
private func renders(_ view: some View, width: CGFloat = 900, height: CGFloat = 700) -> Bool {
    let host = NSHostingView(rootView: view)
    host.frame = NSRect(x: 0, y: 0, width: width, height: height)
    let window = NSWindow(
        contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    defer { window.orderOut(nil) }
    window.contentView = host
    window.layoutIfNeeded()
    host.layoutSubtreeIfNeeded()
    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return false }
    host.cacheDisplay(in: host.bounds, to: rep)
    return rep.pixelsWide > 0 && rep.pixelsHigh > 0
}

@MainActor @Suite(.serialized) struct UISmokeTests {
    init() {
        _ = NSApplication.shared
    }

    @Test func homePageRenders() {
        #expect(renders(HomePage()))
    }

    @Test func mainWindowRendersEveryDestination() {
        let saved = SharedDefaults.store.string(forKey: "mainWindowSection")
        defer {
            if let saved {
                SharedDefaults.store.set(saved, forKey: "mainWindowSection")
            } else {
                SharedDefaults.store.removeObject(forKey: "mainWindowSection")
            }
        }
        for destination in MainDestination.allCases {
            SharedDefaults.store.set(destination.rawValue, forKey: "mainWindowSection")
            #expect(renders(MainWindowView()), "\(destination.rawValue) failed to render")
        }
    }

    @Test func extensionsPaneRenders() {
        #expect(renders(ExtensionsPane()))
    }

    @Test func shortcutsPaneRenders() {
        #expect(renders(ShortcutsPane()))
    }

    @Test func calendarPageRenders() {
        #expect(renders(CalendarPage()))
    }

    @Test func musicPageRenders() {
        #expect(renders(MusicPage()))
    }

    @Test func titlebarChromeRenders() {
        #expect(renders(TitlebarChrome(height: 52, width: 200), width: 220, height: 60))
    }

    @Test func panelTabBarRenders() {
        let tabs: [(id: String, title: String)] = allTabs.map { ($0.id, $0.title) }
        #expect(
            renders(
                TabBar(tabs: tabs, selection: .constant("usage"), theme: .orange),
                width: 480, height: 60))
    }
}
