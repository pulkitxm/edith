import Foundation
import Testing

@testable import Edith
@testable import EdithKit

@MainActor
@Suite struct AttentionPageModelTests {
    @Test func pristineStoreShowsGuidedSetupWithoutActivity() {
        let fixture = fixture()
        defer { fixture.cleanup() }
        let model = AttentionPageModel(repository: fixture.repository)
        #expect(model.needsSetup)
        #expect(model.hasActivity == false)
        #expect(model.summary.entities.isEmpty)
        #expect(model.events.isEmpty)
    }

    @Test func completingSetupPersistsRealSourceChoices() {
        let fixture = fixture()
        defer { fixture.cleanup() }
        let model = AttentionPageModel(repository: fixture.repository)
        model.completeSetup(applicationTracking: true, browserTracking: false)
        let settings = fixture.repository.loadSettings()
        #expect(settings.isEnabled)
        #expect(settings.trackingEnabled)
        #expect(settings.browserTrackingEnabled == false)
        #expect(model.needsSetup == false)
        #expect(model.hasActivity == false)
    }

    @Test func masterSwitchStopsCollectionWithoutLosingSourceChoices() {
        let fixture = fixture()
        defer { fixture.cleanup() }
        let model = AttentionPageModel(repository: fixture.repository)
        model.completeSetup(applicationTracking: true, browserTracking: true)
        model.setAttentionEnabled(false)
        let settings = fixture.repository.loadSettings()
        #expect(settings.isEnabled == false)
        #expect(settings.trackingEnabled)
        #expect(settings.browserTrackingEnabled)
        #expect(model.browserConnected == false)
    }

    @Test func categoryMenuReclassifiesExistingEntity() throws {
        let fixture = fixture()
        defer { fixture.cleanup() }
        let now = Date()
        try fixture.repository.append(
            AttentionEvent(
                startedAt: now.addingTimeInterval(-120), duration: 60,
                source: .application, appName: "Writing", bundleID: "com.example.Writing"))
        let model = AttentionPageModel(repository: fixture.repository)
        model.range = .today
        model.reload()
        let entity = try #require(model.summary.entities.first)
        model.assign(entity: entity, to: "focus")
        #expect(model.summary.focusedDuration == 60)
    }

    @Test func rangesCoverExpectedWindows() {
        let now = Date(timeIntervalSince1970: 1_775_000_000)
        #expect(AttentionViewRange.week.interval(now: now).duration >= 6 * 86_400)
        #expect(AttentionViewRange.month.interval(now: now).duration >= 29 * 86_400)
    }

    @Test func timelineIconsUseApplicationBundlesAndWebsiteFavicons() {
        let now = Date()
        let application = AttentionEvent(
            startedAt: now, duration: 30, source: .application, appName: "Music",
            bundleID: "com.apple.Music")
        let website = AttentionEvent(
            startedAt: now, duration: 30, source: .browser, domain: "meet.google.com",
            faviconURL: "https://meet.google.com/favicon.ico")

        #expect(
            AttentionEventIconDescriptor(event: application)
                == .application(bundleID: "com.apple.Music"))
        #expect(
            AttentionEventIconDescriptor(event: website)
                == .website(URL(string: "https://meet.google.com/favicon.ico")))
    }

    @Test func timelineIconsRejectLocalFaviconSchemesAndKeepSourceFallbacks() {
        let now = Date()
        let website = AttentionEvent(
            startedAt: now, duration: 30, source: .browser, domain: "settings",
            faviconURL: "file:///tmp/favicon.ico")
        let media = AttentionEvent(
            startedAt: now, duration: 30, source: .media,
            media: AttentionMedia(
                title: "Track", service: "Music", kind: "audio", playing: true))
        let manual = AttentionEvent(startedAt: now, duration: 30, source: .manual)

        #expect(AttentionEventIconDescriptor(event: website) == .website(nil))
        #expect(AttentionEventIconDescriptor(event: media) == .symbol("music.note"))
        #expect(AttentionEventIconDescriptor(event: manual) == .symbol("hand.tap"))
    }

    @Test func summaryIconsPreferFaviconsThenApplicationBundles() {
        let category = AttentionSettings.defaultCategories[0]
        let website = AttentionEntity(
            id: "github", name: "github.com", category: category, source: .browser,
            duration: 30, bundleID: "com.google.Chrome",
            faviconURL: "https://github.com/favicon.ico")
        let application = AttentionEntity(
            id: "edith", name: "Edith", category: category, source: .application,
            duration: 30, bundleID: "com.pulkit.edith")

        #expect(
            AttentionEventIconDescriptor(entity: website)
                == .website(URL(string: "https://github.com/favicon.ico")))
        #expect(
            AttentionEventIconDescriptor(entity: application)
                == .application(bundleID: "com.pulkit.edith"))
    }

    private func fixture() -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-attention-page-\(UUID().uuidString)")
        return Fixture(root: root, repository: AttentionRepository(root: root))
    }

    private struct Fixture {
        let root: URL
        let repository: AttentionRepository

        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }
}
