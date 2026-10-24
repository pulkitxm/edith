import EdithExtensionSupport
import EdithExtensionUI
import AppKit
import Foundation
import Testing
import WebKit
@testable import SocialManagerExtension

@MainActor @Suite(.serialized)
struct SocialManagerTests {
    @Test func mixedPlatformsCanBeGroupedResizedSeparatedAndClosedWithoutReplacingBrowsers() throws
    {
        let fixture = try SocialManagerFixture()
        defer { fixture.remove() }
        let model = fixture.model
        let accounts = model.catalog.accounts
        model.open(accounts[0])
        let firstBrowser = try #require(model.sessions[accounts[0].id]?.selectedPage?.webView)
        model.open(accounts[1])
        #expect(model.tabs.count == 2)
        model.sessions[accounts[0].id]?.onFocus?()
        #expect(model.currentTab?.focused == accounts[1].id.uuidString)
        model.open(accounts[0], beside: true)
        #expect(model.tabs.count == 1)
        #expect(model.currentTab?.layout.paneCount == 2)
        model.sessions[accounts[1].id]?.onFocus?()
        #expect(model.currentTab?.focused == accounts[1].id.uuidString)
        #expect(model.sessions[accounts[0].id]?.selectedPage?.webView === firstBrowser)
        for account in accounts.dropFirst(2) { model.open(account, beside: true) }
        #expect(model.currentTab?.layout.paneCount == 6)
        #expect(Set(model.currentTab?.layout.panes ?? []).count == 6)
        model.grid()
        let tab = try #require(model.currentTab)
        let rect = CGRect(x: 0, y: 0, width: 1200, height: 800)
        let frames = tab.layout.paneFrames(in: rect, gap: 6)
        #expect(frames.count == 6)
        #expect(Set(frames.values.map(\.minY)).count == 2)
        let divider = try #require(tab.layout.paneDividers(in: rect, gap: 6).first)
        model.resize(split: divider.splitID, index: divider.index, change: 0.1)
        #expect(model.currentTab?.layout != tab.layout)
        model.toggleZoom(accounts[0].id.uuidString)
        #expect(model.currentTab?.zoomed == accounts[0].id.uuidString)
        model.separate()
        #expect(model.tabs.count == 6)
        #expect(model.sessions.count == 6)
        #expect(model.sessions[accounts[0].id]?.selectedPage?.webView === firstBrowser)
        model.closeTab(try #require(model.selectedTabID))
        #expect(model.tabs.count == 5)
        #expect(model.sessions.count == 5)
        model.shutdown()
        #expect(model.sessions.isEmpty)
        #expect(try fixture.file.load().accounts.count == 6)
    }

    @Test func persistentCookiesAndWebsiteStorageStaySeparateAndSurviveBrowserRecreation()
        async throws
    {
        _ = TestWindowHost.application
        let server = try BrowserHTTPFixture(pages: [
            "/": "<html><head><title>Mock social</title></head><body>Mock account</body></html>"
        ])
        defer { server.stop() }
        let origin = try await server.origin()
        let firstID = UUID()
        let secondID = UUID()
        var first: SocialBrowserSession? = SocialBrowserSession(
            accountID: firstID, website: origin,
            dataStore: WKWebsiteDataStore(forIdentifier: firstID))
        var second: SocialBrowserSession? = SocialBrowserSession(
            accountID: secondID, website: origin,
            dataStore: WKWebsiteDataStore(forIdentifier: secondID))
        do {
            let firstPage = try #require(first?.selectedPage)
            let secondPage = try #require(second?.selectedPage)
            try await loaded(firstPage)
            try await loaded(secondPage)
            _ = try await firstPage.webView.evaluateJavaScript(
                "document.cookie='session=mock-studio; path=/; max-age=86400'; localStorage.setItem('account','mock-studio')"
            )
            _ = try await secondPage.webView.evaluateJavaScript(
                "document.cookie='session=mock-client; path=/; max-age=86400'; localStorage.setItem('account','mock-client')"
            )
            #expect(
                try await firstPage.webView.evaluateJavaScript("localStorage.getItem('account')")
                    as? String == "mock-studio")
            #expect(
                try await secondPage.webView.evaluateJavaScript("document.cookie") as? String
                    == "session=mock-client")
            let savedFirstCookies = await firstPage.webView.configuration.websiteDataStore
                .httpCookieStore.allCookies()
            let savedSecondCookies = await secondPage.webView.configuration.websiteDataStore
                .httpCookieStore.allCookies()
            #expect(savedFirstCookies.map(\.value) == ["mock-studio"])
            #expect(savedSecondCookies.map(\.value) == ["mock-client"])
            let popup = try #require(first?.makePage())
            popup.webView.load(URLRequest(url: origin))
            try await loaded(popup)
            #expect(
                try await popup.webView.evaluateJavaScript("document.cookie") as? String
                    == "session=mock-studio")
            #expect(
                try await popup.webView.evaluateJavaScript("localStorage.getItem('account')")
                    as? String == "mock-studio")
        }
        first?.shutdown()
        first = nil
        second?.shutdown()
        second = nil
        await Task.yield()
        var restored: SocialBrowserSession? = SocialBrowserSession(
            accountID: firstID, website: origin,
            dataStore: WKWebsiteDataStore(forIdentifier: firstID))
        do {
            let page = try #require(restored?.selectedPage)
            try await loaded(page)
            #expect(
                try await page.webView.evaluateJavaScript("document.cookie") as? String
                    == "session=mock-studio")
            #expect(
                try await page.webView.evaluateJavaScript("localStorage.getItem('account')")
                    as? String == "mock-studio")
        }
        restored?.shutdown()
        restored = nil
        await Task.yield()
        var unaffected: SocialBrowserSession? = SocialBrowserSession(
            accountID: secondID, website: origin,
            dataStore: WKWebsiteDataStore(forIdentifier: secondID))
        do {
            let page = try #require(unaffected?.selectedPage)
            try await loaded(page)
            let cookie = try await page.webView.evaluateJavaScript("document.cookie") as? String
            #expect(cookie == "session=mock-client")
            await clearStore(firstID)
            let cookieAfterClearingOtherAccount =
                try await page.webView.evaluateJavaScript("document.cookie") as? String
            #expect(cookieAfterClearingOtherAccount == "session=mock-client")
            #expect(
                try await page.webView.evaluateJavaScript("localStorage.getItem('account')")
                    as? String == "mock-client")
        }
        unaffected?.shutdown()
        unaffected = nil
        await Task.yield()
        await clearStore(secondID)
    }

    @Test func clearingAndRemovingAnAccountLeaveOtherAccountsSignedIn() async throws {
        let server = try BrowserHTTPFixture(pages: [
            "/": "<html><head><title>Mock social</title></head><body>Mock account</body></html>"
        ])
        defer { server.stop() }
        let fixture = try SocialManagerFixture(website: await server.origin(), persistent: true)
        defer { fixture.remove() }
        let model = fixture.model
        let first = model.catalog.accounts[0]
        let second = model.catalog.accounts[1]
        for account in [first, second] {
            model.open(account)
            let page = try #require(model.sessions[account.id]?.selectedPage)
            try await loaded(page)
            _ = try await page.webView.evaluateJavaScript(
                "document.cookie='session=mock-\(account.name.lowercased()); path=/; max-age=86400'"
            )
        }
        model.closeAccount(second.id.uuidString)
        await model.clearSession(first, removingAccount: false)
        #expect(model.message == "Session cleared. Open the account to sign in again.")
        #expect(model.catalog.accounts.contains(first))
        model.open(second)
        try await loaded(try #require(model.sessions[second.id]?.selectedPage))
        model.open(first)
        do {
            let page = try #require(model.sessions[first.id]?.selectedPage)
            try await loaded(page)
            #expect(try await page.webView.evaluateJavaScript("document.cookie") as? String == "")
            let other = try #require(model.sessions[second.id]?.selectedPage)
            #expect(
                try await other.webView.evaluateJavaScript("document.cookie") as? String
                    == "session=mock-personal")
        }
        let removedProfile = try #require(model.profile(for: first))
        await model.removeProfile(removedProfile)
        #expect(!model.catalog.accounts.contains(first))
        #expect(model.catalog.accounts.allSatisfy { $0.profileID != removedProfile.id })
        #expect(model.catalog.profiles.count == 1)
        #expect(model.catalog.accounts.count == 3)
        do {
            let other = try #require(model.sessions[second.id]?.selectedPage)
            #expect(
                try await other.webView.evaluateJavaScript("document.cookie") as? String
                    == "session=mock-personal")
        }
        #expect(try fixture.file.load() == model.catalog)
        await model.clearSession(second, removingAccount: true)
        #expect(!model.catalog.accounts.contains(second))
    }

    @Test func editsPreserveTheSessionAndInvalidNamesDoNotReplaceTheCatalog() throws {
        let fixture = try SocialManagerFixture()
        defer { fixture.remove() }
        let model = fixture.model
        let account = try #require(model.catalog.accounts.first)
        model.open(account)
        let browser = try #require(model.sessions[account.id])
        let updated = try model.saveAccount(
            id: account.id, profileID: account.profileID, platformID: account.platformID,
            name: "Renamed studio", badge: "ST")
        #expect(updated.id == account.id)
        #expect(model.sessions[account.id] === browser)
        #expect(model.currentTab.map(model.title) == "Studio / Renamed studio")
        #expect(throws: SocialAccountError.self) {
            try model.saveAccount(
                profileID: account.profileID, platformID: account.platformID, name: "  ", badge: "")
        }
        #expect(try fixture.file.load() == model.catalog)
        model.shutdown()
    }

    @Test func profilesShowOnlyTheirAddedPlatformsAndRenamingKeepsSessions() throws {
        let fixture = try SocialManagerFixture()
        defer { fixture.remove() }
        let model = fixture.model
        let studio = model.catalog.profiles[0]
        let personal = model.catalog.profiles[1]
        #expect(model.accounts(in: studio).count == 3)
        #expect(model.accounts(in: personal).count == 3)
        #expect(
            Set(model.accounts(in: studio).map(\.id)).isDisjoint(
                with: model.accounts(in: personal).map(\.id)))
        let youtube = try #require(model.catalog.platforms.first { $0.name == "YouTube" })
        let account = try model.saveAccount(
            profileID: studio.id, platformID: youtube.id, name: "Studio channel", badge: "")
        #expect(model.accounts(in: studio).contains(account))
        #expect(!model.accounts(in: personal).contains(account))
        model.open(account)
        let browser = try #require(model.sessions[account.id])
        try model.saveProfile(id: studio.id, name: "New Studio", badge: "NS")
        #expect(model.currentTab.map(model.title) == "New Studio / Studio channel")
        #expect(model.sessions[account.id] === browser)
        #expect(try fixture.file.load() == model.catalog)
        #expect(throws: SocialAccountError.self) {
            try model.saveAccount(
                profileID: UUID(), platformID: youtube.id, name: "Orphan", badge: "")
        }
        let empty = try model.saveProfile(name: "New client", badge: "")
        #expect(model.accounts(in: empty).isEmpty)
        let custom = try model.addWebsite(
            profileID: empty.id, name: "Community", website: "community.example.test")
        #expect(model.accounts(in: empty) == [custom])
        #expect(
            model.platform(for: custom)?.website.absoluteString == "https://community.example.test")
        #expect(!model.accounts(in: personal).contains(custom))
    }

    private func loaded(_ page: SocialBrowserPage) async throws {
        let deadline = ContinuousClock.now + .seconds(20)
        while page.isLoading || page.title != "Mock social" {
            if let error = page.error {
                throw NSError(
                    domain: "SocialFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: error])
            }
            guard ContinuousClock.now < deadline else { throw CocoaError(.fileReadUnknown) }
            try await Task.sleep(for: .milliseconds(30))
        }
    }

    private func clearStore(_ id: UUID) async {
        let store = WKWebsiteDataStore(forIdentifier: id)
        await withCheckedContinuation { continuation in
            store.removeData(
                ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast
            ) {
                continuation.resume()
            }
        }
    }
}

@MainActor
struct SocialManagerFixture {
    let folder: URL
    let file: SocialAccountFile
    let model: SocialManagerModel
    let defaults: UserDefaults

    init(website: URL = URL(string: "about:blank")!, persistent: Bool = false) throws {
        _ = TestWindowHost.application
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            "social-manager-\(UUID().uuidString)")
        file = SocialAccountFile(url: folder.appendingPathComponent("accounts.json"))
        defaults = try #require(UserDefaults(suiteName: folder.lastPathComponent))
        var catalog = SocialAccountCatalog()
        catalog.profiles = [
            SocialProfile(name: "Studio", badge: "ST"), SocialProfile(name: "Personal", badge: "P"),
        ]
        let names = ["Studio", "Personal", "Client North", "Client South", "Community", "Updates"]
        catalog.accounts = names.enumerated().map { index, name in
            SocialAccount(
                profileID: catalog.profiles[index % 2].id,
                platformID: catalog.platforms[index / 2].id, name: name)
        }
        try file.save(catalog)
        model = SocialManagerModel(
            file: file, defaults: defaults,
            sessionFactory: { account, _, dataStore in
                SocialBrowserSession(
                    accountID: account.id, website: website,
                    dataStore: dataStore
                        ?? (persistent
                            ? WKWebsiteDataStore(forIdentifier: account.dataStoreID)
                            : .nonPersistent()))
            })
        model.start()
    }

    func remove() {
        model.shutdown()
        defaults.removePersistentDomain(forName: folder.lastPathComponent)
        try? FileManager.default.removeItem(at: folder)
    }
}
