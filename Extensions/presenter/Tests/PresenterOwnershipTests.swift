import EdithExtensionSupport
import Foundation
import Testing
@testable import PresenterExtension

@Suite struct PresenterOwnershipTests {
    @MainActor @Test func lateScansCannotReactivateADisabledDetector() {
        let suite = "fixture.presenter.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let detector = PresenterDetector(
            scanner: PresenterScanner(
                source: PresenterFixtures.source(PresenterBox([]), titles: true),
                jev: PresenterJevCheck(enabled: { false }, decider: { nil })),
            system: PresenterSystem(
                runningBundleIDs: { ["us.zoom.xos"] }, remoteSessionActive: { true },
                displayMirrored: { true }, announce: {}),
            defaults: defaults, monitoring: false)
        #expect(detector.publishedActive)
        detector.shutdown()
        detector.applyScan(PresenterScan(windowReason: "Late result", recordingHit: true))
        detector.tickSession()
        detector.pauseUntilShareEnds()
        detector.applySettings()
        #expect(!detector.publishedActive)
        #expect(detector.publishedReason == nil)
        #expect(!defaults.bool(forKey: AppStorageKeys.Presenter.autoActive))
    }

    @MainActor @Test func privacyStateIsPublishedWithoutSharingPreferenceSuites() throws {
        let suite = "fixture.presenter.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let channel = ExtensionSharedState(root: root, namespace: suite, owner: "presenter")
        defaults.set(true, forKey: AppStorageKeys.Presenter.enabled)
        defaults.set(true, forKey: AppStorageKeys.Presenter.mode)
        let state = PresenterState(defaults: defaults, state: channel)
        #expect(channel.values(for: "presenter")["active"] == "1")
        #expect(channel.values(for: "presenter")["blurCalendar"] == "1")
        #expect(channel.values(for: "presenter")["blurUsage"] == "0")
        defaults.set(false, forKey: AppStorageKeys.Presenter.blurCalendar)
        state.refresh()
        #expect(channel.values(for: "presenter")["blurCalendar"] == "0")
        state.shutdown()
        state.refresh()
        #expect(channel.values(for: "presenter")["active"] == "0")
    }

    @Test func jevRequestsUseTheOwnedServiceContract() throws {
        let payload = try PresenterJevClient.request(windows: "synthetic window")
        let call = try JSONSerialization.jsonObject(with: payload) as! [String: Any]
        #expect(call["purpose"] as? String == "presenter.detect")
        let request = call["request"] as! [String: Any]
        #expect(request["model"] as? String == "jev-latest")
        #expect((request["state"] as? [String: String])?["windows"] == "synthetic window")
        let questions = request["questions"] as! [String: [String: String]]
        #expect(questions["presenting"]?["type"] == "noul")
    }

    @Test func shutdownPreventsFutureJevRequests() async {
        let decider = PresenterScriptedDecider(probability: 0.95)
        let check = PresenterJevCheck(enabled: { true }, decider: { decider })
        check.shutdown()
        #expect(check.reason(for: PresenterJevCheckTests.meetWindows) == nil)
        await check.settle()
        #expect(decider.requests.isEmpty)
    }
}
