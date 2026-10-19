import AppKit
import Foundation
import Testing
import WebKit

@testable import Edith
@testable import EdithKit

@MainActor @Suite(.serialized)
struct SocialBrowserMenuTests {
    private static let page = "<html><head><title>Mock Feed</title></head><body><p>a < b & \"c\"</p></body></html>"

    @Test func pageMenusOfferBrowserActionsAndShowTheSourceInANewWebsiteTab() async throws {
        _ = TestWindowHost.application
        let server = try BrowserHTTPFixture(pages: ["/": Self.page])
        defer { server.stop() }
        let origin = try await server.origin()
        let session = SocialBrowserSession(
            accountID: UUID(), website: origin, dataStore: .nonPersistent())
        defer { session.shutdown() }
        let page = try #require(session.selectedPage)
        try await eventually { !page.isLoading && page.url == origin }
        #expect(
            page.webView.configuration.preferences.value(forKey: "developerExtrasEnabled") as? Bool
                == true)

        let menu = Self.menu(["WKMenuItemIdentifierGoBack", "WKMenuItemIdentifierReload"])
        menu.addItem(.separator())
        menu.addItem(Self.item("WKMenuItemIdentifierInspectElement", "Inspect Element"))
        page.webView.willOpenMenu(menu, with: Self.rightClick)
        #expect(
            menu.items.map(\.title) == [
                "WKMenuItemIdentifierGoBack", "WKMenuItemIdentifierReload", "", "Save Page As…",
                "Print…", "", "View Page Source", "Inspect Element",
            ])

        let source = try #require(menu.items.first { $0.title == "View Page Source" })
        NSApp.sendAction(try #require(source.action), to: source.target, from: source)
        try await eventually {
            session.pages.count == 2 && session.selectedPage?.title.hasPrefix("view-source:") == true
        }
        let viewer = try #require(session.selectedPage)
        #expect(viewer.title == "view-source:\(origin.absoluteString)")
        let text = try await viewer.webView.evaluateJavaScript("document.body.innerText") as? String
        #expect(text?.contains(Self.page) == true)
    }

    @Test func linkMenusOpenInNewTabsAndBlankPagesKeepTheDefaultMenu() throws {
        let session = SocialBrowserSession(
            accountID: UUID(), website: URL(string: "about:blank")!, dataStore: .nonPersistent())
        defer { session.shutdown() }
        let page = try #require(session.selectedPage)
        let menu = NSMenu()
        menu.addItem(Self.item("WKMenuItemIdentifierOpenLinkInNewWindow", "Open Link in New Window"))
        menu.addItem(Self.item("WKMenuItemIdentifierReload", "Reload"))
        page.webView.willOpenMenu(menu, with: Self.rightClick)
        #expect(menu.items.map(\.title) == ["Open Link in New Tab", "Reload"])
    }

    @Test func sourceViewerEscapesMarkupAndNumbersEveryLine() {
        let html = SocialPageSource.html(
            "<b>one</b>\n\"two\" & three", url: URL(string: "https://example.test/?a=1&b=2")!)
        #expect(html.contains("<title>view-source:https://example.test/?a=1&amp;b=2</title>"))
        #expect(html.contains("<div>&lt;b&gt;one&lt;/b&gt;</div><div>&quot;two&quot; &amp; three</div>"))
        #expect(!html.contains("<b>one"))
    }

    private static var rightClick: NSEvent {
        NSEvent.mouseEvent(
            with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    private static func menu(_ identifiers: [String]) -> NSMenu {
        let menu = NSMenu()
        for identifier in identifiers { menu.addItem(item(identifier, identifier)) }
        return menu
    }

    private static func item(_ identifier: String, _ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.identifier = NSUserInterfaceItemIdentifier(identifier)
        return item
    }

    private func eventually(
        _ timeout: Duration = .seconds(15), _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("Condition did not become true in time")
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}
