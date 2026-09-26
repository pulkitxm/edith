import Foundation
import Testing
import WebKit

@testable import EdithHelper
@testable import EdithKit

@Suite struct ChromeSafeStorageTests {
    @Test func keyDerivationMatchesChromiumsMacRecipe() {
        let hex = SyntheticChrome.key.bytes.map { String(format: "%02x", $0) }.joined()
        #expect(hex == "43cd689954dd16b7f963a77a009324c1")
    }

    @Test func decryptsWithAndWithoutTheHostHashPrefix() throws {
        let key = SyntheticChrome.key
        let prefixed = try #require(
            ChromeSafeStorage.encrypt("mock-value", key: key, host: ".example.com"))
        #expect(prefixed.prefix(3) == Data("v10".utf8))
        #expect(
            ChromeSafeStorage.decrypt(prefixed, key: key, host: ".example.com", hashPrefixed: true)
                == "mock-value")
        let plain = try #require(ChromeSafeStorage.encrypt("legacy", key: key, host: nil))
        #expect(
            ChromeSafeStorage.decrypt(plain, key: key, host: ".example.com", hashPrefixed: false)
                == "legacy")
        #expect(
            ChromeSafeStorage.decrypt(plain, key: key, host: ".example.com", hashPrefixed: true)
                == "legacy")
    }

    @Test func rejectsForeignBlobsAndWrongKeys() throws {
        let blob = try #require(
            ChromeSafeStorage.encrypt("secret", key: SyntheticChrome.key, host: nil))
        let wrong = ChromeCookieKey(passphrase: "not-the-key")
        #expect(
            ChromeSafeStorage.decrypt(blob, key: wrong, host: "a", hashPrefixed: false) != "secret")
        #expect(
            ChromeSafeStorage.decrypt(
                Data("v11abc".utf8), key: SyntheticChrome.key, host: "a", hashPrefixed: false)
                == nil)
        #expect(
            ChromeSafeStorage.decrypt(
                Data("v10abc".utf8), key: SyntheticChrome.key, host: "a", hashPrefixed: false)
                == nil)
    }
}

@Suite struct ChromeCookieReaderTests {
    @Test func chromeTimestampsRoundTrip() throws {
        let date = Date(timeIntervalSince1970: 1_750_000_000)
        let micros = ChromeCookieReader.chromeMicroseconds(date)
        #expect(micros == 13_394_473_600_000_000)
        let back = try #require(ChromeCookieReader.date(chromeMicroseconds: micros))
        #expect(abs(back.timeIntervalSince(date)) < 0.001)
        #expect(ChromeCookieReader.date(chromeMicroseconds: 0) == nil)
    }

    @Test func readsDecryptsAndFiltersCookies() throws {
        let chrome = try SyntheticChrome(profiles: [
            SyntheticChromeProfile(
                directory: "Default", name: "Ada",
                cookies: [
                    SyntheticChromeCookie(
                        host: ".example.com", name: "sid", value: "mock-session", secure: true,
                        httpOnly: true, sameSite: 2),
                    SyntheticChromeCookie(host: "app.example.com", name: "pref", value: "dark"),
                    SyntheticChromeCookie(
                        host: "example.com", name: "tab", value: "session-only", expires: nil,
                        sameSite: -1),
                    SyntheticChromeCookie(
                        host: "old.example.com", name: "gone", value: "x",
                        expires: Date(timeIntervalSinceNow: -60)),
                    SyntheticChromeCookie(
                        host: "plain.example.com", name: "legacy", value: "clear-text",
                        encrypted: false),
                ])
        ])
        defer { chrome.remove() }
        let database = chrome.root.appendingPathComponent("Default/Cookies")
        let cookies = try ChromeCookieReader.read(database: database, key: SyntheticChrome.key)
        let byName = Dictionary(uniqueKeysWithValues: cookies.map { ($0.name, $0) })
        #expect(Set(byName.keys) == ["sid", "pref", "tab", "legacy"])
        #expect(byName["sid"]?.value == "mock-session")
        #expect(byName["sid"]?.isSecure == true)
        #expect(byName["sid"]?.isHTTPOnly == true)
        #expect(byName["sid"]?.sameSite == .strict)
        #expect(byName["pref"]?.sameSite == .lax)
        #expect(byName["tab"]?.expires == nil)
        #expect(byName["tab"]?.sameSite == .unspecified)
        #expect(byName["legacy"]?.value == "clear-text")
    }

    @Test func olderDatabasesDecryptWithoutTheHostHash() throws {
        let chrome = try SyntheticChrome(
            profiles: [
                SyntheticChromeProfile(
                    directory: "Default", name: "Ada",
                    cookies: [SyntheticChromeCookie(host: ".a.com", name: "n", value: "v23")])
            ], cookieVersion: 23)
        defer { chrome.remove() }
        let cookies = try ChromeCookieReader.read(
            database: chrome.root.appendingPathComponent("Default/Cookies"),
            key: SyntheticChrome.key)
        #expect(cookies.map(\.value) == ["v23"])
    }

    @Test func incrementalReadsOnlyReturnNewerCookies() throws {
        let chrome = try SyntheticChrome(profiles: [
            SyntheticChromeProfile(
                directory: "Default", name: "Ada",
                cookies: [
                    SyntheticChromeCookie(
                        host: ".a.com", name: "old", value: "1",
                        updated: Date(timeIntervalSinceNow: -7200)),
                    SyntheticChromeCookie(
                        host: ".a.com", name: "new", value: "2",
                        updated: Date(timeIntervalSinceNow: -10)),
                ])
        ])
        defer { chrome.remove() }
        let cookies = try ChromeCookieReader.read(
            database: chrome.root.appendingPathComponent("Default/Cookies"),
            key: SyntheticChrome.key, updatedAfter: Date(timeIntervalSinceNow: -3600))
        #expect(cookies.map(\.name) == ["new"])
    }

    @Test func partitionedCookiesStayBehind() throws {
        let chrome = try SyntheticChrome(profiles: [
            SyntheticChromeProfile(
                directory: "Default", name: "Ada",
                cookies: [
                    SyntheticChromeCookie(host: ".embed.com", name: "first", value: "1"),
                    SyntheticChromeCookie(
                        host: ".embed.com", name: "third", value: "2",
                        partition: "https://host.com"),
                ])
        ])
        defer { chrome.remove() }
        let cookies = try ChromeCookieReader.read(
            database: chrome.root.appendingPathComponent("Default/Cookies"),
            key: SyntheticChrome.key)
        #expect(cookies.map(\.name) == ["first"])
    }

    @Test func snapshotFingerprintsNoticeWrites() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-fingerprint-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let database = folder.appendingPathComponent("Cookies")
        try Data("one".utf8).write(to: database)
        let first = ChromeCookieReader.fingerprint(database)
        #expect(first == ChromeCookieReader.fingerprint(database))
        try Data("journal".utf8).write(to: URL(fileURLWithPath: database.path + "-journal"))
        #expect(first != ChromeCookieReader.fingerprint(database))
    }

    @Test func wrongKeysSkipCookiesInsteadOfImportingGarbage() throws {
        let chrome = try SyntheticChrome(profiles: [
            SyntheticChromeProfile(
                directory: "Default", name: "Ada",
                cookies: [SyntheticChromeCookie(host: ".a.com", name: "n", value: "v")])
        ])
        defer { chrome.remove() }
        let cookies = try ChromeCookieReader.read(
            database: chrome.root.appendingPathComponent("Default/Cookies"),
            key: ChromeCookieKey(passphrase: "wrong"))
        #expect(cookies.allSatisfy { $0.value != "v" })
    }

    @Test func missingDatabasesThrow() {
        #expect(throws: ChromeCookieReaderError.missingDatabase) {
            try ChromeCookieReader.read(
                database: URL(fileURLWithPath: "/tmp/edith-missing-\(UUID().uuidString)"),
                key: SyntheticChrome.key)
        }
    }

    @Test func cookiesConvertToWebKitCookies() throws {
        let cookie = ChromeCookie(
            host: ".example.com", name: "sid", value: "v", path: "",
            expires: Date(timeIntervalSinceNow: 3600), isSecure: true, isHTTPOnly: true,
            sameSite: .lax, updated: Date())
        let converted = try #require(cookie.httpCookie)
        #expect(converted.domain == ".example.com")
        #expect(converted.path == "/")
        #expect(converted.isSecure)
        #expect(converted.isHTTPOnly)
        #expect(converted.sameSitePolicy == .sameSiteLax)
        #expect(converted.expiresDate != nil)
        let session = ChromeCookie(
            host: "a.com", name: "s", value: "v", path: "/x", expires: nil, isSecure: false,
            isHTTPOnly: false, sameSite: .none, updated: Date())
        #expect(session.httpCookie?.isSessionOnly == true)
        #expect(session.httpCookie?.sameSitePolicy == nil)
    }

    @Test func profileSnapshotsCombineCookiesAndLocalStorage() throws {
        let chrome = try SyntheticChrome(profiles: [
            SyntheticChromeProfile(
                directory: "Profile 1", name: "Work",
                cookies: [SyntheticChromeCookie(host: ".a.com", name: "n", value: "v")],
                localStorage: [
                    "https://a.com": ["token": "mock-token", "theme": "dark"],
                    "https://b.com": ["x": "y"],
                ])
        ])
        defer { chrome.remove() }
        let profile = try #require(chrome.userData.profiles().first)
        #expect(profile.name == "Work")
        let full = try ChromeProfileImporter.snapshot(
            profile: profile, userData: chrome.userData, key: SyntheticChrome.key,
            cookiesUpdatedAfter: nil, includeLocalStorage: true)
        #expect(full.cookies.map(\.value) == ["v"])
        #expect(full.localStorage["https://a.com"] == ["token": "mock-token", "theme": "dark"])
        #expect(full.localStorage["https://b.com"] == ["x": "y"])
        let incremental = try ChromeProfileImporter.snapshot(
            profile: profile, userData: chrome.userData, key: SyntheticChrome.key,
            cookiesUpdatedAfter: Date(), includeLocalStorage: false)
        #expect(incremental.cookies.isEmpty)
        #expect(incremental.localStorage.isEmpty)
    }
}

@Suite(.serialized) @MainActor struct NotchBrowserStoreTests {
    private static let page = """
        <html><head><title>loading</title><script>
        document.title = "cookie=" + document.cookie + " storage="
          + (window.localStorage.getItem("token") || "none");
        </script></head><body>fixture</body></html>
        """

    @MainActor private struct Harness {
        let store: NotchBrowserStore
        let chrome: SyntheticChrome
        let server: BrowserHTTPFixture
        let origin: URL
        let sessionFolder: URL

        func tearDown() {
            store.shutdown()
            server.stop()
            chrome.remove()
            try? FileManager.default.removeItem(at: sessionFolder)
        }
    }

    private func harness(installed: Bool = true, defaultBrowser: String = "com.google.Chrome")
        async throws -> Harness
    {
        let server = try BrowserHTTPFixture(pages: ["/": Self.page, "/two": Self.page])
        let origin = try await server.origin()
        let host = origin.host() ?? "127.0.0.1"
        let storageOrigin = try #require(BrowserTab.origin(of: origin))
        let chrome = try SyntheticChrome(profiles: [
            SyntheticChromeProfile(
                directory: "Default", name: "Mock Personal", email: "mock@example.com",
                cookies: [SyntheticChromeCookie(host: host, name: "session", value: "mock-sid")],
                localStorage: [
                    storageOrigin: ["token": "mock-token"],
                    "https://unvisited.example": ["token": "mock-unvisited"],
                ]),
            SyntheticChromeProfile(directory: "Profile 1", name: "Mock Work"),
        ])
        let sessionFolder = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-browser-session-\(UUID().uuidString)", isDirectory: true)
        let sessionFile = BrowserSessionFile(url: sessionFolder.appendingPathComponent("s.json"))
        sessionFile.save(BrowserSession(tabs: [origin.absoluteString]))
        let installation = ChromeInstallation(
            applicationURL: { installed ? URL(fileURLWithPath: "/Applications/Chrome.app") : nil },
            defaultBrowser: { (defaultBrowser, "Mock Browser") },
            userData: chrome.userData)
        let store = NotchBrowserStore(
            installation: installation, sessionFile: sessionFile,
            defaults: UserDefaults(suiteName: "test.notch-browser.\(UUID().uuidString)")!,
            keyProvider: { SyntheticChrome.key },
            dataStoreFactory: { _ in WKWebsiteDataStore.nonPersistent() })
        return Harness(
            store: store, chrome: chrome, server: server, origin: origin,
            sessionFolder: sessionFolder)
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

    @Test func setupReflectsTheChromeInstallation() async throws {
        let missing = try await harness(installed: false)
        defer { missing.tearDown() }
        #expect(missing.store.readiness == .notInstalled)
        #expect(missing.store.profiles.isEmpty)
        #expect(missing.store.showsSetup)

        let secondary = try await harness(defaultBrowser: "com.apple.Safari")
        defer { secondary.tearDown() }
        #expect(secondary.store.readiness == .notDefault(currentBrowser: "Mock Browser"))
        #expect(secondary.store.profiles.map(\.name) == ["Mock Personal", "Mock Work"])
        #expect(secondary.store.profiles.first?.email == "mock@example.com")
    }

    @Test func attachingAProfileCarriesCookiesAndLocalStorageIntoWebKit() async throws {
        let harness = try await harness()
        defer { harness.tearDown() }
        let store = harness.store
        #expect(store.readiness == .ready)
        store.attach(store.profiles[0])
        try await eventually { store.profile != nil && store.syncState == .idle }
        #expect(store.profile?.name == "Mock Personal")
        #expect(store.syncSummary == "1 cookie from 1 site, local storage for 2")
        #expect(!store.showsSetup)
        #expect(store.tabs.count == 1)
        let tab = try #require(store.selectedTab)
        try await eventually { tab.title.hasPrefix("cookie=") }
        #expect(tab.title == "cookie=session=mock-sid storage=mock-token")
        let storageOrigin = try #require(BrowserTab.origin(of: harness.origin))
        try await eventually { store.pendingSeeds[storageOrigin] == nil }
        #expect(Array(store.pendingSeeds.keys) == ["https://unvisited.example"])
    }

    @Test func tabsOpenCloseReorderAndReopen() async throws {
        let harness = try await harness()
        defer { harness.tearDown() }
        let store = harness.store
        store.attach(store.profiles[0])
        try await eventually { store.profile != nil && store.tabs.count == 1 }
        let first = try #require(store.tabs.first)
        try await eventually { first.url != nil && first.isLoading == false }
        let second = try #require(
            store.newTab(harness.origin.appendingPathComponent("two"), select: true))
        let third = try #require(store.newTab(URL(string: "about:blank"), after: first))
        #expect(store.tabs.map(\.id) == [first.id, third.id, second.id])
        #expect(store.selectedTabID == third.id)

        store.move(third, to: 2)
        #expect(store.tabs.map(\.id) == [first.id, second.id, third.id])
        store.selectRelative(1)
        #expect(store.selectedTabID == first.id)
        store.perform(.selectTab(1))
        #expect(store.selectedTabID == second.id)
        store.perform(.lastTab)
        #expect(store.selectedTabID == third.id)

        try await eventually { second.url?.path == "/two" }
        store.close(second)
        #expect(store.tabs.map(\.id) == [first.id, third.id])
        #expect(store.canReopenClosedTab)
        store.reopenClosedTab()
        #expect(store.tabs.count == 3)
        try await eventually { store.selectedTab?.webView.url?.path == "/two" }

        store.closeToRight(first)
        #expect(store.tabs.map(\.id) == [first.id])
        store.closeOthers(first)
        #expect(store.tabs.map(\.id) == [first.id])
        store.close(first)
        #expect(store.tabs.count == 1)
        #expect(store.tabs.first?.id != first.id)
    }

    @Test func switchingProfilesNeverCarriesAnotherProfilesStorage() async throws {
        let harness = try await harness()
        defer { harness.tearDown() }
        let store = harness.store
        store.attach(store.profiles[0])
        try await eventually { store.profile?.directory == "Default" && store.syncState == .idle }
        #expect(store.pendingSeeds["https://unvisited.example"] == ["token": "mock-unvisited"])
        store.attach(store.profiles[1])
        try await eventually { store.profile?.directory == "Profile 1" && store.syncState == .idle }
        #expect(store.pendingSeeds.isEmpty)
    }

    @Test func restoringASessionKeepsTheSelectedTab() async throws {
        let harness = try await harness()
        defer { harness.tearDown() }
        let file = BrowserSessionFile(url: harness.sessionFolder.appendingPathComponent("s.json"))
        let second = harness.origin.appendingPathComponent("two")
        file.save(
            BrowserSession(
                tabs: [harness.origin.absoluteString, second.absoluteString], selected: 1))
        let store = NotchBrowserStore(
            installation: harness.store.installation, sessionFile: file,
            defaults: UserDefaults(suiteName: "test.notch-browser.\(UUID().uuidString)")!,
            keyProvider: { SyntheticChrome.key },
            dataStoreFactory: { _ in WKWebsiteDataStore.nonPersistent() })
        defer { store.shutdown() }
        store.attach(store.profiles[0])
        try await eventually { store.tabs.count == 2 }
        #expect(store.selectedTabID == store.tabs[1].id)
        #expect(file.load().selected == 1)
        #expect(file.load().tabs == [harness.origin.absoluteString, second.absoluteString])
    }

    @Test func holdOpenStateAndSizeChangesReachTheNotch() async throws {
        let harness = try await harness()
        defer { harness.tearDown() }
        let store = harness.store
        var sizeChanges = 0
        store.onSizeChange = { sizeChanges += 1 }
        store.screenSize = { CGSize(width: 1512, height: 982) }
        store.applySize(CGSize(width: 5000, height: 200))
        #expect(store.size == CGSize(width: 1464, height: NotchBrowserGeometry.minimumSize.height))
        #expect(sizeChanges == 1)
        store.applySize(CGSize(width: 5000, height: 200))
        #expect(sizeChanges == 1)
        store.resetSize()
        #expect(store.size == NotchBrowserGeometry.defaultSize)
        #expect(!store.holdsOpen)
        store.beginResize(.bottom)
        #expect(store.holdsOpen)
        store.endResize()
        #expect(!store.holdsOpen)
    }

    @Test func detachingForgetsTheProfileAndItsTabs() async throws {
        let harness = try await harness()
        defer { harness.tearDown() }
        let store = harness.store
        store.attach(store.profiles[1])
        try await eventually { store.profile?.directory == "Profile 1" }
        #expect(store.syncSummary == "0 cookies from 0 sites")
        store.chooseProfile()
        #expect(store.showsSetup)
        store.cancelChoosingProfile()
        #expect(!store.showsSetup)
        store.detach()
        #expect(store.profile == nil)
        #expect(store.tabs.isEmpty)
        #expect(store.showsSetup)
        #expect(
            BrowserSessionFile(url: harness.sessionFolder.appendingPathComponent("s.json"))
                .load().profile == nil)
    }

    @Test func attachAndDetachNameTheProfileForSettingsAndAnnounceIt() async throws {
        let harness = try await harness()
        defer { harness.tearDown() }
        let store = harness.store
        let file = BrowserSessionFile(url: harness.sessionFolder.appendingPathComponent("s.json"))
        var announcements = 0
        store.onProfileChange = { announcements += 1 }
        store.attach(store.profiles[1])
        try await eventually { store.profile?.directory == "Profile 1" }
        #expect(announcements == 1)
        #expect(file.load().attachedProfileName == "Mock Work")
        store.syncNow()
        try await eventually { store.syncState == .idle }
        #expect(announcements == 1)
        store.detach()
        #expect(announcements == 2)
        #expect(file.load().attachedProfileName == nil)
        #expect(file.load().profileName == nil)
    }

    @Test func keychainFailuresSurfaceWithoutAttaching() async throws {
        let server = try BrowserHTTPFixture(pages: [:])
        defer { server.stop() }
        let chrome = try SyntheticChrome(profiles: [
            SyntheticChromeProfile(directory: "Default", name: "Mock")
        ])
        defer { chrome.remove() }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-browser-deny-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = NotchBrowserStore(
            installation: ChromeInstallation(
                applicationURL: { URL(fileURLWithPath: "/Applications/Chrome.app") },
                defaultBrowser: { ("com.google.Chrome", "Google Chrome") },
                userData: chrome.userData),
            sessionFile: BrowserSessionFile(url: folder.appendingPathComponent("s.json")),
            defaults: UserDefaults(suiteName: "test.notch-browser.\(UUID().uuidString)")!,
            keyProvider: { throw ChromeSafeStorageError.keychainDenied(-128) },
            dataStoreFactory: { _ in WKWebsiteDataStore.nonPersistent() })
        defer { store.shutdown() }
        store.attach(store.profiles[0])
        #expect(store.syncState == .unlocking)
        #expect(store.holdsOpen)
        try await eventually {
            if case .failed = store.syncState { return true }
            return false
        }
        #expect(
            store.syncState
                == .failed(ChromeSafeStorageError.keychainDenied(-128).localizedDescription))
        #expect(store.profile == nil)
        #expect(store.tabs.isEmpty)
    }
}
