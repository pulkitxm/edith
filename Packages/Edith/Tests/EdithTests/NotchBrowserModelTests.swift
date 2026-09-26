import AppKit
import CoreGraphics
import Foundation
import Testing

@testable import EdithCore
@testable import EdithHelper
@testable import EdithKit

@Suite struct ChromeProfileParserTests {
    private let root = URL(fileURLWithPath: "/tmp/fixture-chrome", isDirectory: true)

    private func localState(_ cache: [String: [String: Any]], order: [String]? = nil) -> Data {
        var profile: [String: Any] = ["info_cache": cache]
        if let order { profile["profiles_order"] = order }
        return try! JSONSerialization.data(withJSONObject: ["profile": profile])
    }

    @Test func followsChromeOrderAndSkipsMissingFolders() {
        let data = localState(
            [
                "Default": ["name": "Personal", "user_name": "ada@example.com"],
                "Profile 2": ["name": "Side"],
                "Profile 1": ["name": "Work"],
                "Profile 9": ["name": "Gone"],
            ], order: ["Profile 1", "Default"])
        let present: Set<String> = ["Default", "Profile 1", "Profile 2"]
        let profiles = ChromeProfileParser.profiles(
            localState: data, root: root, exists: { present.contains($0.lastPathComponent) })
        #expect(profiles.map(\.directory) == ["Profile 1", "Default", "Profile 2"])
        #expect(profiles.map(\.name) == ["Work", "Personal", "Side"])
        #expect(profiles[1].email == "ada@example.com")
        #expect(profiles[0].email == nil)
    }

    @Test func defaultNamedProfilesShowTheGoogleGivenName() {
        let info: [String: Any] = [
            "name": "Person 1", "is_using_default_name": true, "gaia_given_name": "Ada",
            "gaia_name": "Ada Lovelace",
        ]
        #expect(ChromeProfileParser.displayName(info, directory: "Default") == "Ada")
        #expect(
            ChromeProfileParser.displayName(["name": "  "], directory: "Profile 3") == "Profile 3")
        #expect(
            ChromeProfileParser.displayName(["gaia_name": "Grace Hopper"], directory: "Default")
                == "Grace Hopper")
    }

    @Test func picturesAndColorsResolveFromTheProfileFolder() {
        let data = localState([
            "Default": [
                "name": "Ada", "gaia_picture_file_name": "Google Profile Picture.png",
                "profile_highlight_color": -16_744_449,
            ],
            "Profile 1": ["name": "Bo", "gaia_id": "42", "default_avatar_fill_color": 0xFF00_FF00],
        ])
        let files: Set<String> = [
            root.appendingPathComponent("Default").path,
            root.appendingPathComponent("Default/Google Profile Picture.png").path,
            root.appendingPathComponent("Profile 1").path,
            root.appendingPathComponent("Profile 1/Accounts/Avatar Images/42").path,
        ]
        let profiles = ChromeProfileParser.profiles(
            localState: data, root: root, exists: { files.contains($0.path) })
        #expect(profiles.count == 2)
        #expect(profiles[0].pictureURL?.lastPathComponent == "Google Profile Picture.png")
        #expect(profiles[0].colorARGB == 0xFF00_7FFF)
        #expect(profiles[1].pictureURL?.path.hasSuffix("Accounts/Avatar Images/42") == true)
        #expect(profiles[1].colorARGB == 0xFF00_FF00)
    }

    @Test func malformedLocalStateYieldsNoProfiles() {
        #expect(
            ChromeProfileParser.profiles(
                localState: Data("{}".utf8), root: root, exists: { _ in true }
            )
            .isEmpty)
        #expect(
            ChromeProfileParser.profiles(
                localState: Data("nope".utf8), root: root, exists: { _ in true }
            )
            .isEmpty)
    }

    @Test func initialsUseTheFirstTwoWords() {
        let profile = ChromeProfile(
            directory: "Default", name: "ada lovelace king", email: nil, pictureURL: nil,
            colorARGB: nil)
        #expect(profile.initials == "AL")
        let blank = ChromeProfile(
            directory: "Default", name: "", email: nil, pictureURL: nil, colorARGB: nil)
        #expect(blank.initials == "?")
    }

    @Test func userDataPrefersTheNewestCookieDatabase() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-chrome-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let profile = ChromeProfile(
            directory: "Default", name: "Ada", email: nil, pictureURL: nil, colorARGB: nil)
        let userData = ChromeUserData(root: folder)
        #expect(userData.cookiesURL(for: profile) == nil)
        let network = folder.appendingPathComponent("Default/Network", isDirectory: true)
        try FileManager.default.createDirectory(at: network, withIntermediateDirectories: true)
        let legacy = folder.appendingPathComponent("Default/Cookies")
        let modern = network.appendingPathComponent("Cookies")
        try Data("a".utf8).write(to: legacy)
        try Data("b".utf8).write(to: modern)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -600)], ofItemAtPath: legacy.path)
        #expect(userData.cookiesURL(for: profile)?.path == modern.path)
        #expect(
            userData.localStorageURL(for: profile).path.hasSuffix("Default/Local Storage/leveldb"))
    }
}

@Suite struct ChromeReadinessTests {
    @Test func readinessCoversEveryInstallState() {
        let chrome = (bundleIdentifier: "com.google.Chrome", name: "Google Chrome")
        let safari = (bundleIdentifier: "com.apple.Safari", name: "Safari")
        #expect(
            ChromeInstallation.readiness(installed: false, defaultBrowser: chrome, profileCount: 2)
                == .notInstalled)
        #expect(
            ChromeInstallation.readiness(installed: true, defaultBrowser: chrome, profileCount: 0)
                == .noProfiles)
        #expect(
            ChromeInstallation.readiness(installed: true, defaultBrowser: safari, profileCount: 1)
                == .notDefault(currentBrowser: "Safari"))
        #expect(
            ChromeInstallation.readiness(installed: true, defaultBrowser: nil, profileCount: 1)
                == .notDefault(currentBrowser: nil))
        #expect(
            ChromeInstallation.readiness(installed: true, defaultBrowser: chrome, profileCount: 1)
                == .ready)
    }

    @Test func onlyInstalledChromeWithProfilesCanAttach() {
        #expect(ChromeReadiness.ready.allowsAttaching)
        #expect(ChromeReadiness.notDefault(currentBrowser: "Safari").allowsAttaching)
        #expect(!ChromeReadiness.notInstalled.allowsAttaching)
        #expect(!ChromeReadiness.noProfiles.allowsAttaching)
        #expect(!ChromeReadiness.unreadable("denied").allowsAttaching)
    }

    @Test func unreadableUserDataIsReportedInsteadOfNoProfiles() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-chrome-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(
            at: folder.appendingPathComponent("Local State"), withIntermediateDirectories: true)
        let chrome = ChromeInstallation(
            applicationURL: { URL(fileURLWithPath: "/Applications/Chrome.app") },
            defaultBrowser: { ("com.google.Chrome", "Google Chrome") },
            userData: ChromeUserData(root: folder))
        let inspection = chrome.inspect()
        guard case .unreadable(let reason) = inspection.readiness else {
            Issue.record("expected unreadable, got \(inspection.readiness)")
            return
        }
        #expect(!reason.isEmpty)
        #expect(inspection.profiles.isEmpty)
        let missing = ChromeInstallation(
            applicationURL: { URL(fileURLWithPath: "/Applications/Chrome.app") },
            defaultBrowser: { ("com.google.Chrome", "Google Chrome") },
            userData: ChromeUserData(root: folder.appendingPathComponent("nowhere")))
        #expect(missing.inspect().readiness == .noProfiles)
    }
}

@Suite struct BrowserAddressTests {
    @Test func hostsBecomeSecureURLs() {
        #expect(
            BrowserAddress.url(for: "github.com/apple", engine: .google)?.absoluteString
                == "https://github.com/apple")
        #expect(
            BrowserAddress.url(for: "  news.ycombinator.com  ", engine: .google)?.absoluteString
                == "https://news.ycombinator.com")
    }

    @Test func localAddressesStayPlainHTTP() {
        #expect(
            BrowserAddress.url(for: "localhost:3000/app", engine: .google)?.absoluteString
                == "http://localhost:3000/app")
        #expect(
            BrowserAddress.url(for: "127.0.0.1:8080", engine: .google)?.absoluteString
                == "http://127.0.0.1:8080")
    }

    @Test func fullURLsPassThrough() {
        #expect(
            BrowserAddress.url(for: "http://example.com/a?b=1", engine: .google)?.absoluteString
                == "http://example.com/a?b=1")
        #expect(
            BrowserAddress.url(for: "about:blank", engine: .google)?.absoluteString == "about:blank"
        )
    }

    @Test func textAndUnsafeSchemesBecomeSearches() {
        let search = BrowserAddress.url(for: "swift concurrency", engine: .google)
        #expect(search?.host() == "www.google.com")
        #expect(search?.query()?.contains("swift%20concurrency") == true)
        let script = BrowserAddress.url(for: "javascript:alert(1)", engine: .duckDuckGo)
        #expect(script?.host() == "duckduckgo.com")
        #expect(BrowserAddress.url(for: "   ", engine: .google) == nil)
        #expect(BrowserAddress.url(for: "notatld", engine: .bing)?.host() == "www.bing.com")
    }

    @Test func everyEngineBuildsAQueryURL() {
        for engine in BrowserSearchEngine.allCases {
            let url = engine.searchURL(for: "a&b")
            #expect(url?.host() == engine.home.host())
            #expect(
                URLComponents(url: url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value
                    == "a&b")
        }
    }

    @Test func blankPagesShowAnEmptyAddress() {
        #expect(BrowserAddress.displayText(for: URL(string: "about:blank")) == "")
        #expect(BrowserAddress.displayText(for: nil) == "")
        #expect(
            BrowserAddress.displayText(for: URL(string: "https://a.dev/x")) == "https://a.dev/x")
    }
}

@Suite struct BrowserShortcutTests {
    @Test func commandShortcutsMapToBrowserActions() {
        #expect(BrowserShortcut.match(characters: "t", modifiers: .command) == .newTab)
        #expect(BrowserShortcut.match(characters: "w", modifiers: .command) == .closeTab)
        #expect(
            BrowserShortcut.match(characters: "T", modifiers: [.command, .shift])
                == .reopenClosedTab)
        #expect(BrowserShortcut.match(characters: "l", modifiers: .command) == .focusAddress)
        #expect(BrowserShortcut.match(characters: "r", modifiers: .command) == .reload)
        #expect(
            BrowserShortcut.match(characters: "R", modifiers: [.command, .shift]) == .hardReload)
        #expect(BrowserShortcut.match(characters: "[", modifiers: .command) == .back)
        #expect(BrowserShortcut.match(characters: "]", modifiers: .command) == .forward)
        #expect(BrowserShortcut.match(characters: "}", modifiers: [.command, .shift]) == .nextTab)
        #expect(
            BrowserShortcut.match(characters: "{", modifiers: [.command, .shift]) == .previousTab)
        #expect(BrowserShortcut.match(characters: "3", modifiers: .command) == .selectTab(2))
        #expect(BrowserShortcut.match(characters: "9", modifiers: .command) == .lastTab)
        #expect(BrowserShortcut.match(characters: "=", modifiers: .command) == .zoomIn)
        #expect(BrowserShortcut.match(characters: "-", modifiers: .command) == .zoomOut)
        #expect(BrowserShortcut.match(characters: "0", modifiers: .command) == .zoomReset)
    }

    @Test func controlTabCyclesAndEditKeysRouteToTheResponder() {
        #expect(BrowserShortcut.match(characters: "\t", modifiers: .control) == .nextTab)
        #expect(
            BrowserShortcut.match(characters: "\t", modifiers: [.control, .shift]) == .previousTab)
        #expect(BrowserShortcut.match(characters: "c", modifiers: .command)?.editAction != nil)
        #expect(BrowserShortcut.match(characters: "v", modifiers: .command) == .paste)
        #expect(BrowserShortcut.match(characters: "z", modifiers: [.command, .shift]) == .redo)
        #expect(BrowserShortcut.newTab.editAction == nil)
    }

    @Test func unrelatedKeysAreLeftToThePage() {
        #expect(BrowserShortcut.match(characters: "k", modifiers: .command) == nil)
        #expect(BrowserShortcut.match(characters: "t", modifiers: []) == nil)
        #expect(BrowserShortcut.match(characters: "t", modifiers: [.command, .option]) == nil)
    }
}

@Suite struct NotchBrowserGeometryTests {
    private let screen = CGSize(width: 1512, height: 982)

    @Test func clampKeepsTheBrowserOnScreenAndAboveTheMinimum() {
        #expect(
            NotchBrowserGeometry.clamp(CGSize(width: 100, height: 100), screen: screen)
                == NotchBrowserGeometry.minimumSize)
        #expect(
            NotchBrowserGeometry.clamp(CGSize(width: 5000, height: 5000), screen: screen)
                == CGSize(width: 1464, height: 970))
        #expect(
            NotchBrowserGeometry.clamp(CGSize(width: 900.4, height: 700.6), screen: screen)
                == CGSize(width: 900, height: 701))
    }

    @Test func thePanelKeepsTheBrowserSizeSoAnimationsNeverResizeIt() {
        #expect(NotchGeometry.panelShape(browserShape: nil) == NotchGeometry.expandedMaxSize)
        #expect(
            NotchGeometry.panelShape(browserShape: CGSize(width: 1000, height: 672))
                == CGSize(width: 1000, height: 672))
        #expect(
            NotchGeometry.panelShape(browserShape: CGSize(width: 620, height: 300))
                == CGSize(width: 620, height: NotchGeometry.expandedMaxSize.height))
    }

    @Test func clicksOutsideTheExpandedShapeFallThrough() {
        let shape = CGRect(x: 100, y: 500, width: 400, height: 300)
        func accepts(_ point: CGPoint, pressed: Bool = false, held: Bool = false) -> Bool {
            NotchGeometry.expandedAcceptsPointer(
                point, shapeFrame: shape, buttonPressed: pressed, heldOpen: held)
        }
        #expect(accepts(CGPoint(x: 300, y: 600)))
        #expect(accepts(CGPoint(x: 97, y: 600)))
        #expect(!accepts(CGPoint(x: 80, y: 600)))
        #expect(!accepts(CGPoint(x: 300, y: 450)))
        #expect(accepts(CGPoint(x: 300, y: 450), pressed: true))
        #expect(accepts(CGPoint(x: 300, y: 450), held: true))
    }

    @Test func theNotchHeightComesOutOfTheAvailableHeight() {
        let area = NotchBrowserGeometry.available(screen: screen, notchHeight: 38)
        #expect(area == CGSize(width: 1512, height: 944))
        let tallest = NotchBrowserGeometry.clamp(CGSize(width: 900, height: 5000), screen: area)
        #expect(tallest.height + 38 <= screen.height)
    }

    @Test func bottomHandleOnlyChangesHeight() {
        let size = NotchBrowserGeometry.resized(
            from: CGSize(width: 900, height: 600), edge: .bottom,
            pointerStart: CGPoint(x: 700, y: 400), pointer: CGPoint(x: 760, y: 300),
            screen: screen)
        #expect(size == CGSize(width: 900, height: 700))
    }

    @Test func cornersGrowSymmetricallyAroundTheNotch() {
        let trailing = NotchBrowserGeometry.resized(
            from: CGSize(width: 900, height: 600), edge: .bottomTrailing,
            pointerStart: CGPoint(x: 1000, y: 400), pointer: CGPoint(x: 1050, y: 420),
            screen: screen)
        #expect(trailing == CGSize(width: 1000, height: 580))
        let leading = NotchBrowserGeometry.resized(
            from: CGSize(width: 900, height: 600), edge: .bottomLeading,
            pointerStart: CGPoint(x: 300, y: 400), pointer: CGPoint(x: 250, y: 400),
            screen: screen)
        #expect(leading == CGSize(width: 1000, height: 600))
    }

    @Test func notchShapeGrowsToTheBrowserAndThePanelNeverShrinksBelowTheShelf() {
        let shape = NotchGeometry.expandedShapeSize(
            tab: .browser, hasMusic: false, notchHeight: 32,
            browserSize: CGSize(width: 1000, height: 640))
        #expect(shape == CGSize(width: 1000, height: 672))
        #expect(
            NotchGeometry.panelCapacity(forShape: CGSize(width: 300, height: 900))
                == CGSize(width: NotchGeometry.expandedWidth, height: 900))
        #expect(
            NotchGeometry.union(CGSize(width: 1, height: 9), CGSize(width: 5, height: 2))
                == CGSize(width: 5, height: 9))
        #expect(
            NotchGeometry.expandedShapeSize(tab: .files, hasMusic: false, notchHeight: 32).width
                == NotchGeometry.expandedWidth)
    }
}

@Suite struct NotchBrowserTabVisibilityTests {
    @Test func browserTabFollowsHomeOnlyWhenEnabled() {
        #expect(
            NotchTab.visible(
                clipboardEnabled: false, audioMixerEnabled: false,
                applicationAudioSupported: false, browserEnabled: true)
                == [.home, .browser, .files, .camera])
        #expect(
            !NotchTab.visible(
                clipboardEnabled: true, audioMixerEnabled: true, applicationAudioSupported: true
            ).contains(.browser))
        #expect(NotchTab.validSelection(.browser, visible: [.home, .files]) == .home)
        #expect(NotchTab.browser.title == "Browser")
        #expect(NotchTab.browser.icon == "globe")
    }
}

@Suite struct LocalStorageSeedTests {
    @Test func scriptGuardsTheOriginAndOnlyFillsMissingKeys() throws {
        let script = try #require(
            LocalStorageSeed.script(
                origin: "https://app.example.com", items: ["token": "a\"b</script>", "n": "1"]))
        #expect(script.contains("window.location.origin !== \"https:\\/\\/app.example.com\""))
        #expect(script.contains("store.getItem(key) === null"))
        #expect(script.contains(LocalStorageSeed.messageName))
        #expect(script.contains("\"token\":\"a\\\"b<\\/script>\""))
    }

    @Test func oversizedOriginsAreSkipped() {
        let big = String(repeating: "x", count: LocalStorageSeed.originLimitBytes + 1)
        #expect(LocalStorageSeed.script(origin: "https://a.com", items: ["k": big]) == nil)
        let importable = LocalStorageSeed.importable([
            "https://a.com": ["k": big], "https://b.com": ["k": "v"], "https://c.com": [:],
        ])
        #expect(Array(importable.keys) == ["https://b.com"])
    }
}

@Suite struct BrowserTabOriginTests {
    @Test func originsDropDefaultPortsAndIgnoreOtherSchemes() {
        #expect(BrowserTab.origin(of: URL(string: "https://A.com/x?y")!) == "https://a.com")
        #expect(BrowserTab.origin(of: URL(string: "https://a.com:443/")!) == "https://a.com")
        #expect(BrowserTab.origin(of: URL(string: "http://a.com:8080/")!) == "http://a.com:8080")
        #expect(BrowserTab.origin(of: URL(string: "about:blank")!) == nil)
        #expect(BrowserTab.origin(of: URL(string: "file:///tmp/a.html")!) == nil)
    }

    @Test @MainActor func webMenusOfferTabsInsteadOfWindows() {
        let menu = NSMenu()
        let open = NSMenuItem(title: "Open Link in New Window", action: nil, keyEquivalent: "")
        open.identifier = NSUserInterfaceItemIdentifier("WKMenuItemIdentifierOpenLinkInNewWindow")
        let copy = NSMenuItem(title: "Copy Link", action: nil, keyEquivalent: "")
        copy.identifier = NSUserInterfaceItemIdentifier("WKMenuItemIdentifierCopyLink")
        menu.items = [open, copy]
        NotchWebMenu.retitle(menu)
        #expect(open.title == "Open Link in New Tab")
        #expect(copy.title == "Copy Link")
    }
}

@Suite struct BrowserSessionTests {
    @Test func sessionsRoundTripAndOnlyRestoreWebPages() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-session-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = BrowserSessionFile(url: folder.appendingPathComponent("nested/session.json"))
        #expect(file.load() == BrowserSession())
        let session = BrowserSession(
            profile: "Profile 1",
            tabs: ["https://a.com/", "about:blank", "file:///etc/hosts", "http://b.dev:81/x"],
            selected: 3, width: 1000, height: 700)
        file.save(session)
        let loaded = file.load()
        #expect(loaded == session)
        #expect(loaded.size == CGSize(width: 1000, height: 700))
        #expect(
            loaded.restorableURLs.map(\.absoluteString) == ["https://a.com/", "http://b.dev:81/x"])
        file.remove()
        #expect(file.load() == BrowserSession())
    }

    @Test func downloadsNeverOverwriteExistingFiles() {
        let folder = URL(fileURLWithPath: "/tmp/downloads", isDirectory: true)
        let taken: Set<String> = ["report.pdf", "report (1).pdf", "notes"]
        let exists: (URL) -> Bool = { taken.contains($0.lastPathComponent) }
        #expect(
            NotchBrowserStore.uniqueDestination(in: folder, filename: "report.pdf", exists: exists)
                .lastPathComponent == "report (2).pdf")
        #expect(
            NotchBrowserStore.uniqueDestination(in: folder, filename: "notes", exists: exists)
                .lastPathComponent == "notes (1)")
        #expect(
            NotchBrowserStore.uniqueDestination(in: folder, filename: "a/b.txt", exists: exists)
                .lastPathComponent == "a-b.txt")
        #expect(
            NotchBrowserStore.uniqueDestination(in: folder, filename: "", exists: exists)
                .lastPathComponent == "download")
    }

    @Test func syncSummaryCountsCookiesSitesAndStorage() {
        let cookie = ChromeCookie(
            host: ".a.com", name: "n", value: "v", path: "/", expires: nil, isSecure: true,
            isHTTPOnly: false, sameSite: .lax, updated: Date())
        let other = ChromeCookie(
            host: "a.com", name: "m", value: "v", path: "/", expires: nil, isSecure: true,
            isHTTPOnly: false, sameSite: .lax, updated: Date())
        let snapshot = ChromeProfileSnapshot(
            cookies: [cookie, other], localStorage: ["https://a.com": ["k": "v"]])
        #expect(snapshot.siteCount == 1)
        #expect(
            NotchBrowserStore.summary(applied: 2, snapshot: snapshot)
                == "2 cookies from 1 site, local storage for 1")
        #expect(
            NotchBrowserStore.summary(
                applied: 1, snapshot: ChromeProfileSnapshot(cookies: [cookie], localStorage: [:]))
                == "1 cookie from 1 site")
    }

    @Test func profileStoresAreStablePerProfileAndDistinctAcrossProfiles() {
        let userData = ChromeUserData(root: URL(fileURLWithPath: "/tmp/chrome"))
        let first = ChromeProfile(
            directory: "Default", name: "A", email: nil, pictureURL: nil, colorARGB: nil)
        let second = ChromeProfile(
            directory: "Profile 1", name: "B", email: nil, pictureURL: nil, colorARGB: nil)
        let id = ChromeProfileImporter.dataStoreIdentifier(profile: first, userData: userData)
        #expect(id == ChromeProfileImporter.dataStoreIdentifier(profile: first, userData: userData))
        #expect(
            id != ChromeProfileImporter.dataStoreIdentifier(profile: second, userData: userData))
        #expect(id.uuidString.dropFirst(14).first == "5")
    }
}

@Suite struct NotchBrowserShelfToggleTests {
    private static let sources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Sources")

    private func source(_ path: String) throws -> String {
        try String(contentsOf: Self.sources.appendingPathComponent(path), encoding: .utf8)
    }

    @Test func theBrowserIsPartOfTheNotchShelfNotASeparateExtension() throws {
        #expect(ExtensionRegistry.entry("notchBrowser") == nil)
        #expect(ExtensionLifecycleCatalog.descriptor(for: "notchBrowser") == nil)
        #expect(ExtensionDetailRoute(rawValue: "notchBrowser") == nil)
        #expect(!ExtensionLiveAdapters.extensionIDs.contains("notchBrowser"))
        #expect(
            !ExtensionRegistry.entries.contains {
                $0.defaultsKey == AppStorageKeys.Notch.browserEnabled
            })
        let shelf = try #require(ExtensionRegistry.entry("notchShelf"))
        #expect(shelf.optionalCapabilities.contains(.webBrowsing))
        #expect(shelf.subtitle.contains("browser"))
        #expect(PlatformCapabilities.macOS.state(for: .webBrowsing).isSupported)
        let descriptor = try #require(ExtensionLifecycleCatalog.descriptor(for: "notchShelf"))
        let browser = try #require(descriptor.workflows.first { $0.id == "browser" })
        #expect(browser.command == "ed config set notchBrowserEnabled true")
        #expect(descriptor.prerequisites.contains { $0.id == "chrome" })
        #expect(descriptor.cliExamples.contains("ed config set notchBrowserEnabled true"))
    }

    @Test @MainActor func runtimeNeedsBothTheShelfAndTheBrowserToggle() {
        #expect(
            AppServices.notchBrowserRuntimeEnabled(notchShelfEnabled: true, browserEnabled: true))
        #expect(
            !AppServices.notchBrowserRuntimeEnabled(notchShelfEnabled: false, browserEnabled: true))
        #expect(
            !AppServices.notchBrowserRuntimeEnabled(notchShelfEnabled: true, browserEnabled: false))
    }

    @Test func browserSettingsAreCataloguedUnderTheNotch() throws {
        let toggle = try #require(
            ConfigCatalog.definition(for: AppStorageKeys.Notch.browserEnabled))
        #expect(toggle.fallback == .bool(false))
        #expect(toggle.group == "notch")
        let definition = try #require(
            ConfigCatalog.definition(for: AppStorageKeys.Notch.browserSearchEngine))
        #expect(definition.allowed == BrowserSearchEngine.allCases.map(\.rawValue))
        #expect(definition.fallback == .string("google"))
        #expect(SettingsBackup.backedKeys.contains(AppStorageKeys.Notch.browserSearchEngine))
        #expect(SettingsBackup.backedKeys.contains(AppStorageKeys.Notch.browserEnabled))
    }

    @Test func theShelfSettingsCarryTheBrowserToggleAndItsSettings() throws {
        let rows = try source("Edith/Features/Settings/Views/NotchShelfRows.swift")
        #expect(rows.contains("$browser.configured(AppStorageKeys.Notch.browserEnabled)"))
        #expect(rows.contains("AppStorageKeys.Notch.browserSearchEngine"))
        #expect(rows.contains("NotchBrowserProfileRow()"))
        #expect(rows.contains("IPC.post(IPC.Name.requestNotchBrowserDetach)"))
        #expect(rows.contains("for: IPC.Name.notchBrowserChanged"))
        let pane = try source("Edith/Features/Settings/Views/ExtensionsPane.swift")
        #expect(!pane.contains("NotchBrowserRows"))
    }

    @Test func theHelperDetachesOnRequestAndAnnouncesProfileChanges() throws {
        let app = try source("EdithHelper/Core/Application/EdithHelperApp.swift")
        #expect(app.contains("IPC.observe(IPC.Name.requestNotchBrowserDetach)"))
        #expect(app.contains("services.notchBrowser?.detach()"))
        let services = try source("EdithHelper/Core/Application/AppServices.swift")
        #expect(
            services.contains("store.onProfileChange = { IPC.post(IPC.Name.notchBrowserChanged) }"))
    }

    @Test func sessionsNameTheAttachedProfileForSettings() throws {
        var session = BrowserSession()
        #expect(session.attachedProfileName == nil)
        session.profileName = "Stale"
        #expect(session.attachedProfileName == nil)
        session.profile = "Profile 1"
        #expect(session.attachedProfileName == "Stale")
        session.profileName = nil
        #expect(session.attachedProfileName == "Profile 1")
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-session-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = BrowserSessionFile(url: folder.appendingPathComponent("session.json"))
        session.profileName = "Mock Work"
        file.save(session)
        #expect(file.load().attachedProfileName == "Mock Work")
        #expect(BrowserSessionFile.standard.url.lastPathComponent == "session.json")
        #expect(
            BrowserSessionFile.standard.url.deletingLastPathComponent().lastPathComponent
                == "notch-browser")
    }
}

@Suite struct NotchBrowserHidePolicyTests {
    @Test func browserStaysOpenThroughSmallOvershoots() {
        let shelf = NotchHidePolicy.policy(for: .files)
        let browser = NotchHidePolicy.policy(for: .browser)
        #expect(shelf == .shelf)
        #expect(browser.keepInset > shelf.keepInset)
        #expect(browser.closeGrace > shelf.closeGrace)
        for policy in [shelf, browser] {
            #expect(policy.trackingMargin > policy.keepInset)
        }
    }

    @Test func pointerJustPastTheBrowserEdgeKeepsItOpen() {
        let collapsed = CGRect(x: 700, y: 950, width: 180, height: 32)
        let expanded = CGRect(x: 300, y: 300, width: 980, height: 682)
        let justBelow = CGPoint(x: 790, y: 300 - 50)
        #expect(
            NotchGeometry.proximity(
                point: justBelow, collapsedFrame: collapsed, expandedFrame: expanded,
                keepInset: NotchHidePolicy.browser.keepInset) == .keepOpen)
        #expect(
            NotchGeometry.proximity(
                point: justBelow, collapsedFrame: collapsed, expandedFrame: expanded,
                keepInset: NotchHidePolicy.shelf.keepInset) == .outside)
    }

    @Test func gateUsesTheCurrentCloseGrace() {
        var gate = NotchHoverGate(openDwell: 0.1, closeGrace: 0.4)
        gate.forceOpen()
        gate.closeGrace = NotchHidePolicy.browser.closeGrace
        #expect(gate.sample(.outside, now: 10) == .schedule(deadline: 10.9))
        #expect(gate.fire(now: 10.5) == .schedule(deadline: 10.9))
        #expect(gate.fire(now: 10.9) == .closed)
    }
}

@Suite @MainActor struct BrowserWebContainerTests {
    @Test func rehostingNeverResizesThePageToNothing() {
        let container = BrowserWebContainerView(frame: .zero)
        let webView = NotchWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        container.show(webView)
        #expect(webView.frame.size == CGSize(width: 900, height: 600))
        container.setFrameSize(NSSize(width: 960, height: 620))
        #expect(webView.frame.size == CGSize(width: 960, height: 620))
        container.setFrameSize(.zero)
        container.layout()
        #expect(webView.frame.size == CGSize(width: 960, height: 620))
        let other = NotchWebView(frame: .zero)
        container.setFrameSize(NSSize(width: 800, height: 500))
        container.show(other)
        #expect(other.frame.size == CGSize(width: 800, height: 500))
        #expect(webView.superview == nil)
    }
}
