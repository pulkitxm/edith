import AppKit
import Foundation
import Testing
import WebKit
@testable import NotchShelfExtension

@MainActor @Suite(.serialized) struct NotchBrowserNativePresentationTests {
    @Test func originalInteractiveBrowserImportsEditsNavigatesAndDrainsUnshown() async throws {
        let page = """
            <html><head><title>loading</title><script>
            document.title = 'cookie=' + document.cookie + ' storage=' + localStorage.getItem('token');
            </script></head><body><input id="editor" value="original"><a href="/two">next</a></body></html>
            """
        let server = try BrowserHTTPFixture(pages: [
            "/": page, "/two": "<title>second native page</title>",
        ])
        defer { server.stop() }
        let origin = try await server.origin()
        let storageOrigin = try #require(BrowserTab.origin(of: origin))
        let fixture = try Fixture(
            tabs: [origin.absoluteString],
            cookies: [.init(host: "127.0.0.1", name: "session", value: "mock-session")],
            storage: [storageOrigin: ["token": "mock-token"]])
        defer { fixture.clean() }
        #expect(fixture.store.selectedTab == nil)
        #expect(!fixture.store.permitsNativeNavigation)
        #expect(fixture.store.newTab(URL(string: "about:blank")) == nil)
        fixture.store.appeared()
        try await eventually {
            fixture.store.selectedTab?.title == "cookie=session=mock-session storage=mock-token"
        }
        let tab = try #require(fixture.store.selectedTab)
        let webView = tab.webView
        #expect(webView.window == nil)
        let dataStore = webView.configuration.websiteDataStore
        #expect(!dataStore.isPersistent)
        let importedCookies = await dataStore.httpCookieStore.allCookies()
        #expect(importedCookies.contains { $0.name == "session" && $0.value == "mock-session" })
        let edited = try await webView.evaluateJavaScript(
            "document.getElementById('editor').value = 'edited synthetic text'; document.getElementById('editor').value"
        )
        #expect(edited as? String == "edited synthetic text")
        var focusRequests = 0
        fixture.store.requestKeyFocus = { focusRequests += 1 }
        fixture.store.perform(.focusAddress)
        #expect(focusRequests == 1 && fixture.store.addressFocusRequest == 1)
        fixture.store.submitAddress(origin.appendingPathComponent("two").absoluteString)
        try await eventually { tab.title == "second native page" && tab.canGoBack }
        fixture.store.perform(.back)
        try await eventually { tab.title.hasPrefix("cookie=") && tab.canGoForward }
        fixture.store.perform(.forward)
        try await eventually { tab.title == "second native page" }
        fixture.store.perform(.zoomIn)
        #expect(webView.pageZoom == 1.1)
        fixture.store.perform(.zoomReset)
        #expect(webView.pageZoom == 1)
        let second = try #require(fixture.store.newTab(URL(string: "about:blank")))
        fixture.store.move(second, to: 0)
        #expect(fixture.store.tabs.first?.id == second.id)
        fixture.store.close(second)
        #expect(fixture.store.selectedTabID == tab.id)
        #expect(
            fixture.store.newTab(fixture.chrome.root.appendingPathComponent("private.html")) == nil)
        #expect(!NotchBrowserStore.permittedURL(URL(string: "javascript:alert(1)")!, remote: true))
        #expect(!NotchBrowserStore.permittedURL(URL(string: "edith://privileged")!, remote: true))
        #expect(!NotchBrowserStore.permittedURL(URL(string: "about:config")!, remote: true))
        let oldLease = try #require(fixture.remote.lease)
        await fixture.store.shutdownAndWait()
        #expect(fixture.store.tabs.isEmpty)
        #expect(!fixture.store.permitsNativeNavigation)
        #expect(fixture.remote.lease == nil)
        #expect(webView.navigationDelegate == nil && webView.uiDelegate == nil)
        #expect(webView.configuration.userContentController.userScripts.isEmpty)
        #expect(await dataStore.httpCookieStore.allCookies().isEmpty)
        #expect(
            await dataStore.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()).isEmpty)
        var replay = fixture.request(.leaseRenew)
        replay.lease = oldLease
        await #expect(throws: (any Error).self) { try await fixture.engine.execute(replay) }
        let orphanDelegate = NotchBrowserWebDelegate(store: fixture.store)
        orphanDelegate.webViewWebContentProcessDidTerminate(webView)
        #expect(!webView.isLoading && webView.window == nil)
    }

    @Test func closingDuringActualCookieHandoffDiscardsLatePayloadAndRevokesEngineLease()
        async throws
    {
        let fixture = try Fixture(tabs: [])
        defer { fixture.clean() }
        var pending: CheckedContinuation<Void, Never>?
        var issued: NotchBrowserLease?
        let remote = NotchBrowserRemoteClient(
            state: try fixture.engine.state(), request: { fixture.request($0) },
            invoke: { request in
                let data = try await fixture.engine.execute(request)
                if request.operation == .importStart {
                    issued = try JSONDecoder().decode(NotchBrowserImport.self, from: data).lease
                    await withCheckedContinuation { pending = $0 }
                }
                return data
            })
        let store = NotchBrowserStore(defaults: fixture.defaults, remote: remote)
        store.attach(try #require(remote.state.profiles.first))
        try await eventually { pending != nil }
        store.shutdown()
        pending?.resume(); pending = nil
        await store.shutdownAndWait()
        #expect(store.tabs.isEmpty && remote.lease == nil)
        var replay = fixture.request(.leaseRenew)
        replay.lease = try #require(issued)
        await #expect(throws: (any Error).self) { try await fixture.engine.execute(replay) }
    }

    private func eventually(_ predicate: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(15)
        while !predicate() {
            if ContinuousClock.now >= deadline { throw CocoaError(.coderReadCorrupt) }
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    @MainActor private struct Fixture {
        let chrome: SyntheticChrome
        let engine: NotchBrowserEngine
        let remote: NotchBrowserRemoteClient
        let store: NotchBrowserStore
        let defaults: UserDefaults
        let suite = "notch-native-browser-" + UUID().uuidString
        let identity = NotchPanelIdentity(ownershipID: UUID(), generation: UUID())
        let owner = UUID()

        init(
            tabs: [String], cookies: [SyntheticChromeCookie] = [],
            storage: [String: [String: String]] = [:]
        ) throws {
            chrome = try SyntheticChrome(profiles: [
                .init(
                    directory: "Default", name: "Mock original browser", cookies: cookies,
                    localStorage: storage)
            ])
            let root = chrome.root
            defaults = try #require(UserDefaults(suiteName: suite))
            let session = BrowserSessionFile(url: root.appendingPathComponent("Session.json"))
            session.save(
                .init(profile: "Default", profileName: "Mock original browser", tabs: tabs))
            engine = NotchBrowserEngine(
                installation: .init(
                    applicationURL: { root.appendingPathComponent("Mock Chrome.app") },
                    defaultBrowser: { (ChromeInstallation.bundleIdentifier, "Mock") },
                    userData: chrome.userData),
                sessionFile: session, defaults: defaults, keyProvider: { SyntheticChrome.key },
                open: { _, _ in Issue.record("No app may open") },
                downloads: .init(
                    destination: { root.appendingPathComponent("Downloads") },
                    staging: root.appendingPathComponent("Staging"), completed: { _ in }),
                openURL: { _ in
                    Issue.record("No URL may open"); return false
                })
            let identity = identity
            let owner = owner
            remote = NotchBrowserRemoteClient(
                state: try engine.state(),
                request: {
                    .init(identity: identity, displayID: 42, presentationID: owner, operation: $0)
                },
                invoke: { [engine] in try await engine.execute($0) })
            store = NotchBrowserStore(defaults: defaults, remote: remote)
        }

        func request(_ operation: NotchBrowserRemoteRequest.Operation) -> NotchBrowserRemoteRequest
        {
            .init(identity: identity, displayID: 42, presentationID: owner, operation: operation)
        }

        func clean() {
            store.shutdown(); remote.stop(); engine.stop(); chrome.remove()
            UserDefaults.standard.removePersistentDomain(forName: suite)
        }
    }
}
