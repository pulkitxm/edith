import EdithKit
import Foundation
import Testing

@Suite struct PresenterPrivacyTests {
    @Test func onlyUsageStaysOffUntilChosen() {
        #expect(PresenterPrivacy.allCases.count == 16)
        let expected = PresenterPrivacy.allCases.filter { $0 != .usage }
        #expect(PresenterPrivacy.allCases.filter(\.fallback) == expected)
        #expect(PresenterPrivacy.usage.fallback == false)
    }

    @Test func storageKeysMatchThePresenterDefaultsAndStayUnique() {
        let keys = PresenterPrivacy.allCases.map(\.storageKey)
        #expect(Set(keys).count == keys.count)
        #expect(PresenterPrivacy.music.storageKey == AppStorageKeys.Presenter.blurMusic)
        #expect(PresenterPrivacy.money.storageKey == AppStorageKeys.Presenter.blurMoney)
        #expect(PresenterPrivacy.usage.storageKey == AppStorageKeys.Presenter.blurUsage)
        #expect(PresenterPrivacy.calendar.storageKey == AppStorageKeys.Presenter.blurCalendar)
        #expect(PresenterPrivacy.agents.storageKey == AppStorageKeys.Presenter.blurAgents)
        #expect(PresenterPrivacy.attention.storageKey == AppStorageKeys.Presenter.blurAttention)
        #expect(PresenterPrivacy.camera.storageKey == AppStorageKeys.Presenter.blurCamera)
        #expect(PresenterPrivacy.studio.storageKey == AppStorageKeys.Presenter.blurStudio)
        #expect(PresenterPrivacy.database.storageKey == AppStorageKeys.Presenter.blurDatabase)
        #expect(PresenterPrivacy.memory.storageKey == AppStorageKeys.Presenter.blurMemory)
        #expect(PresenterPrivacy.fleet.storageKey == AppStorageKeys.Presenter.blurFleet)
        #expect(PresenterPrivacy.review.storageKey == AppStorageKeys.Presenter.blurReview)
        #expect(PresenterPrivacy.siteAudit.storageKey == AppStorageKeys.Presenter.blurSiteAudit)
        #expect(PresenterPrivacy.runningApps.storageKey == AppStorageKeys.Presenter.blurRunningApps)
        #expect(PresenterPrivacy.shelf.storageKey == AppStorageKeys.Presenter.blurShelf)
        #expect(PresenterPrivacy.browser.storageKey == AppStorageKeys.Presenter.blurBrowser)
    }

    @Test func hidingFollowsTheStoredChoiceAndTheFallback() {
        let suite = "presenter-privacy-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(PresenterPrivacy.music.hides(active: false, defaults: defaults) == false)
        #expect(PresenterPrivacy.music.hides(active: true, defaults: defaults))
        #expect(PresenterPrivacy.usage.hides(active: true, defaults: defaults) == false)

        defaults.set(false, forKey: PresenterPrivacy.music.storageKey)
        defaults.set(true, forKey: PresenterPrivacy.usage.storageKey)
        #expect(PresenterPrivacy.music.hides(active: true, defaults: defaults) == false)
        #expect(PresenterPrivacy.usage.hides(active: true, defaults: defaults))
        #expect(PresenterPrivacy.browser.hides(active: true, defaults: defaults))
    }
}
