import AppKit
import EdithKit
import Foundation
import Testing
import WebKit

@testable import Edith

@MainActor @Suite(.serialized)
struct SocialAccountBrowsingTests {
    @Test func filtersCombineProfilesPlatformsAndSearchWithoutWritingTheCatalog() throws {
        let fixture = try SocialManagerFixture()
        defer { fixture.remove() }
        let model = fixture.model
        let original = try Data(contentsOf: fixture.file.url)
        let instagram = try #require(model.availablePlatforms.first { $0.name == "Instagram" })
        model.browse(.accounts)
        #expect(model.filteredAccounts.count == 6)
        model.platformFilterID = instagram.id
        #expect(model.filteredAccounts.map(\.name) == ["Studio", "Personal"])
        model.accountProfileFilterID = model.catalog.profiles[1].id
        #expect(model.filteredAccounts.map(\.name) == ["Personal"])
        model.browse(.list)
        #expect(model.platformFilterID == instagram.id)
        #expect(model.filteredAccounts.map(\.name) == ["Personal"])
        model.accountSearch = "studio"
        #expect(model.filteredAccounts.isEmpty)
        model.accountProfileFilterID = nil
        #expect(model.filteredAccounts.map(\.name) == ["Studio"])
        model.accountSearch = "INSTAGRAM"
        #expect(model.filteredAccounts.count == 2)
        #expect(try Data(contentsOf: fixture.file.url) == original)
    }

    @Test func sidebarStartsAcrossAllProfilesAndUsernamesSupportSearchSortingAndOpenFilters() throws
    {
        let fixture = try SocialManagerFixture()
        defer { fixture.remove() }
        let model = fixture.model
        let account = model.catalog.accounts[0]
        let updated = try model.saveAccount(
            id: account.id, profileID: account.profileID, platformID: account.platformID,
            name: account.name, badge: account.badge, username: " @studio.photos ")
        #expect(updated.handle == "@studio.photos")
        #expect(model.accountTitle(updated) == "Studio / @studio.photos")
        model.profileID = account.profileID
        #expect(model.filteredAccounts.count == 6)
        model.accountSearch = "@studio.photos"
        #expect(model.filteredAccounts == [updated])
        model.open(updated)
        model.accountStatus = .closed
        #expect(model.filteredAccounts.isEmpty)
        model.accountStatus = .open
        #expect(model.filteredAccounts == [updated])
        model.resetAccountFilters()
        model.accountSort = .username
        #expect(model.filteredAccounts.first?.name == "Client North")
        model.accountSort = .manual
        #expect(model.filteredAccounts == model.catalog.accounts)
        let cleared = try model.saveAccount(
            id: updated.id, profileID: updated.profileID, platformID: updated.platformID,
            name: updated.name, badge: updated.badge, username: "")
        #expect(cleared.username == nil && cleared.handle == nil)
        #expect(try fixture.file.load().accounts.first?.username == nil)
    }

    @Test func filteredBulkOpeningUsesSharedLayoutTemplatesAndRetainsExistingBrowsers() throws {
        let fixture = try SocialManagerFixture()
        defer { fixture.remove() }
        let model = fixture.model
        let original = try Data(contentsOf: fixture.file.url)
        model.browse(.accounts)
        model.platformFilterID = model.catalog.platforms[0].id
        let accounts = model.filteredAccounts
        model.openAccounts(accounts)
        #expect(model.tabs.count == 2)
        let browsers = model.sessions
        let templates = model.templates(for: accounts.count)
        for template in templates {
            model.openAccounts(accounts, layout: template)
            #expect(model.tabs.count == 1)
            #expect(
                Set(model.currentTab?.layout.panes ?? []) == Set(accounts.map { $0.id.uuidString }))
            #expect(
                model.currentTab?.layout.geometryMatches(
                    try #require(template.layout(accounts.map { $0.id.uuidString }))) == true)
            for account in accounts { #expect(model.sessions[account.id] === browsers[account.id]) }
        }
        model.openAccounts(accounts)
        #expect(model.tabs.count == 2)
        #expect(try Data(contentsOf: fixture.file.url) == original)
        model.browse(.list)
        #expect(model.filteredAccounts == accounts)
    }

    @Test func newlyAddedCustomPlatformsAppearInFiltersWithoutChangingOtherRecords() throws {
        let fixture = try SocialManagerFixture()
        defer { fixture.remove() }
        let model = fixture.model
        let original = model.catalog.accounts
        let custom = try model.addWebsite(
            profileID: model.catalog.profiles[0].id, name: "Community site",
            website: "https://community.example.test")
        #expect(model.availablePlatforms.contains { $0.id == custom.platformID })
        model.browse(.list)
        model.platformFilterID = custom.platformID
        #expect(model.filteredAccounts == [custom])
        #expect(model.catalog.accounts.filter { $0.id != custom.id } == original)
    }

    @Test func accountURLUpdatesHomeWithoutReplacingItsBrowserOrAffectingOtherAccounts() throws {
        let fixture = try SocialManagerFixture()
        defer { fixture.remove() }
        let model = fixture.model
        let account = model.catalog.accounts[0]
        let other = model.catalog.accounts[1]
        model.open(account)
        let browser = try #require(model.sessions[account.id])
        let store = browser.dataStore
        let updated = try model.saveAccount(
            id: account.id, profileID: account.profileID, platformID: account.platformID,
            name: account.name, badge: account.badge, website: "https://studio.youtube.com")
        #expect(updated.id == account.id && updated.dataStoreID == account.dataStoreID)
        #expect(browser.website.absoluteString == "https://studio.youtube.com")
        #expect(model.sessions[account.id] === browser && browser.dataStore === store)
        #expect(model.account(other.id.uuidString) == other)
        let saved = try Data(contentsOf: fixture.file.url)
        #expect(throws: SocialAccountError.self) {
            try model.saveAccount(
                id: account.id, profileID: account.profileID, platformID: account.platformID,
                name: account.name, badge: "", website: "file:///private/data")
        }
        #expect(try Data(contentsOf: fixture.file.url) == saved)
        #expect(try fixture.file.load().accounts.first?.website == updated.website)
    }

    @Test func sharedGoogleCookiesAreProfileScopedAndSwitchingBackRestoresTheSeparateLogin()
        async throws
    {
        let fixture = try SocialManagerFixture(persistent: true)
        defer { fixture.remove() }
        let model = fixture.model
        let profile = model.catalog.profiles[0]
        let youtube = try model.saveAccount(
            profileID: profile.id, platformID: SocialPlatform.presets[3].id, name: "Studio channel",
            badge: "", website: "https://studio.youtube.com")
        model.open(youtube)
        let separateStore = try #require(model.sessions[youtube.id]?.dataStore)
        try await setCookie("separate", in: separateStore)
        model.openEmail(profile)
        let googleStore = try #require(model.sessions[profile.id]?.dataStore)
        try await setCookie("profile-google", in: googleStore)
        let linked = try model.saveAccount(
            id: youtube.id, profileID: profile.id, platformID: youtube.platformID,
            name: youtube.name, badge: "", shareProfileSession: true)
        #expect(linked.dataStoreID == profile.id)
        #expect(model.sessions[youtube.id]?.dataStore === googleStore)
        #expect(await cookies(in: googleStore) == ["profile-google"])
        let otherProfile = model.catalog.profiles[1]
        model.openEmail(otherProfile)
        let otherStore = try #require(model.sessions[otherProfile.id]?.dataStore)
        #expect(await cookies(in: otherStore).isEmpty)
        let independent = try model.saveAccount(
            id: youtube.id, profileID: profile.id, platformID: youtube.platformID,
            name: youtube.name, badge: "", shareProfileSession: false)
        #expect(independent.dataStoreID == youtube.id)
        #expect(model.sessions[youtube.id]?.dataStore === separateStore)
        #expect(await cookies(in: separateStore) == ["separate"])
        #expect(await cookies(in: googleStore) == ["profile-google"])
        #expect(
            try fixture.file.load().accounts.first { $0.id == youtube.id }?.website
                == youtube.website)
        await removeCookies(from: separateStore)
        await removeCookies(from: googleStore)
    }

    @Test
    func removingALinkedAccountKeepsGoogleSignedInAndClearingSharedSessionLeavesOtherProfilesAlone()
        async throws
    {
        let fixture = try SocialManagerFixture()
        defer { fixture.remove() }
        let model = fixture.model
        let profile = model.catalog.profiles[0]
        model.openEmail(profile)
        let googleStore = try #require(model.sessions[profile.id]?.dataStore)
        try await setCookie("profile-google", in: googleStore)
        let linked = try model.saveAccount(
            profileID: profile.id, platformID: SocialPlatform.presets[3].id, name: "Shared channel",
            badge: "", shareProfileSession: true)
        model.open(linked)
        await model.clearSession(linked, removingAccount: true)
        #expect(await cookies(in: googleStore) == ["profile-google"])
        #expect(model.sessions[profile.id] != nil)
        let otherProfile = model.catalog.profiles[1]
        model.openEmail(otherProfile)
        let otherStore = try #require(model.sessions[otherProfile.id]?.dataStore)
        try await setCookie("other-profile", in: otherStore)
        await model.clearSession(
            try #require(model.account(profile.id.uuidString)), removingAccount: false)
        #expect(await cookies(in: googleStore).isEmpty)
        #expect(await cookies(in: otherStore) == ["other-profile"])
        #expect(model.sessions[otherProfile.id] != nil)
    }

    private func setCookie(_ value: String, in store: WKWebsiteDataStore) async throws {
        let cookie = try #require(
            HTTPCookie(properties: [
                .domain: "social.example.test", .path: "/", .name: "session", .value: value,
                .expires: Date().addingTimeInterval(3600),
            ]))
        await store.httpCookieStore.setCookie(cookie)
    }

    private func cookies(in store: WKWebsiteDataStore) async -> [String] {
        await store.httpCookieStore.allCookies().filter { $0.domain == "social.example.test" }.map(
            \.value)
    }

    private func removeCookies(from store: WKWebsiteDataStore) async {
        for cookie in await store.httpCookieStore.allCookies() {
            await store.httpCookieStore.deleteCookie(cookie)
        }
    }
}
