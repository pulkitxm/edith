import AppKit
import Foundation
import Testing
import WebKit

@testable import Edith
@testable import EdithKit

@MainActor @Suite(.serialized)
struct SocialBrowserBasicsTests {
    private static let pages = [
        "/": """
        <html><head><title>Mock Feed</title></head><body>
        <p>first needle here</p>
        <a id="next" href="/next" style="display:block;height:400px">Next post</a>
        </body></html>
        """,
        "/next": "<html><head><title>Mock Post</title></head><body>post</body></html>",
    ]

    @Test func browserShortcutsResolveToPageCommands() {
        func resolve(_ characters: String, _ modifiers: NSEvent.ModifierFlags)
            -> WindowWorkspaceCommand?
        {
            WindowWorkspaceCommand.resolve(characters: characters, keyCode: 0, modifiers: modifiers)
        }
        #expect(resolve("f", .command) == .find)
        #expect(resolve("g", .command) == .findNext)
        #expect(resolve("G", [.command, .shift]) == .findPrevious)
        #expect(resolve("=", .command) == .zoomIn)
        #expect(resolve("+", [.command, .shift]) == .zoomIn)
        #expect(resolve("-", .command) == .zoomOut)
        #expect(resolve("F", [.command, .shift]) == .showFilters)
    }

    @Test func pagesFindTextZoomWithinLimitsAndPlayVideoFullScreen() async throws {
        let server = try BrowserHTTPFixture(pages: Self.pages)
        defer { server.stop() }
        let origin = try await server.origin()
        let session = SocialBrowserSession(
            accountID: UUID(), website: origin, dataStore: .nonPersistent())
        defer { session.shutdown() }
        let page = try #require(session.selectedPage)
        try await eventually { !page.isLoading && page.url == origin }
        #expect(page.webView.configuration.preferences.isElementFullscreenEnabled)

        page.showFind()
        #expect(page.showsFind)
        page.findText = "needle"
        page.find()
        try await eventually { page.findMatched == true }
        page.findText = "absent words"
        page.find(backwards: true)
        try await eventually { page.findMatched == false }
        page.hideFind()
        #expect(!page.showsFind && page.findMatched == nil)

        page.zoom(by: 10)
        #expect(page.webView.pageZoom == 3)
        page.zoom(by: -10)
        #expect(page.webView.pageZoom == 0.5)
    }

    @Test func commandClickedLinksOpenInABackgroundTab() async throws {
        let server = try BrowserHTTPFixture(pages: Self.pages)
        defer { server.stop() }
        let origin = try await server.origin()
        let session = SocialBrowserSession(
            accountID: UUID(), website: origin, dataStore: .nonPersistent())
        defer { session.shutdown() }
        let page = try #require(session.selectedPage)
        try await eventually { !page.isLoading && page.url == origin }

        let window = TestWindowHost.window(contentRect: NSRect(x: 0, y: 0, width: 600, height: 500))
        page.webView.frame = window.contentView!.bounds
        window.contentView!.addSubview(page.webView)
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(300))
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let click = try #require(
                NSEvent.mouseEvent(
                    with: type, location: NSPoint(x: 100, y: 300), modifierFlags: .command,
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                    pressure: type == .leftMouseDown ? 1 : 0))
            window.sendEvent(click)
            try await Task.sleep(for: .milliseconds(100))
        }
        try await eventually { session.pages.count == 2 }
        #expect(session.selectedPageID == page.id)
        #expect(page.url == origin)
        let opened = try #require(session.pages.last)
        try await eventually { opened.url == origin.appendingPathComponent("next") }
    }

    @Test func historyKeysAndMouseButtonsMoveTheHoveredPageBackFirst() async throws {
        let server = try BrowserHTTPFixture(pages: Self.pages)
        defer { server.stop() }
        let origin = try await server.origin()
        let next = origin.appendingPathComponent("next")
        let session = SocialBrowserSession(
            accountID: UUID(), website: origin, dataStore: .nonPersistent())
        defer { session.shutdown() }
        let page = try #require(session.selectedPage)
        try await eventually { !page.isLoading && page.url == origin }
        page.webView.load(URLRequest(url: next))
        try await eventually { !page.isLoading && page.url == next && page.canGoBack }

        let child = NSView()
        page.webView.addSubview(child)
        let found = NavigationShortcutGate.webView(from: child)
        #expect(found === page.webView)
        #expect(NavigationShortcutGate.pageHistory(.back, in: found))
        try await eventually { page.url == origin }
        #expect(!NavigationShortcutGate.pageHistory(.back, in: WKWebView()))
        #expect(!NavigationShortcutGate.pageHistory(.forward, in: nil))
    }

    @Test func theAddressBarSearchesWordsAndOpensPlainAddresses() {
        #expect(
            BrowserAddress.url(for: "mock studio reels", engine: .google)?.absoluteString
                == "https://www.google.com/search?q=mock%20studio%20reels")
        #expect(
            BrowserAddress.url(for: "example.com/feed", engine: .google)?.absoluteString
                == "https://example.com/feed")
        #expect(
            BrowserAddress.url(for: "localhost:3000", engine: .google)?.absoluteString
                == "http://localhost:3000")
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
