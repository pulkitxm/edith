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
