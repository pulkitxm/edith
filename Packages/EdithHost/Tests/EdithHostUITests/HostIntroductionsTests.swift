import EdithHostCore
import Foundation
import Testing

@testable import EdithHost

@MainActor @Suite(.serialized) struct HostIntroductionsTests {
    private func store() -> HostIntroductions {
        let name = "introductions-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return HostIntroductions(defaults: defaults)
    }

    private func entry(_ id: String = "clipboard", guide: Bool = true) -> HostExtension {
        HostExtension(
            id: id, title: id, symbolName: "star", category: "desk",
            guide: guide
                ? HostExtensionGuide(
                    tagline: "t", summary: "s",
                    steps: [HostGuideStep(symbolName: "star", title: "a", detail: "b")])
                : nil)
    }

    @Test func firstVisitPresentsOnce() {
        let intros = store()
        let tool = entry()
        #expect(intros.shouldPresent(tool))
        intros.markSeen(tool.id)
        #expect(!intros.shouldPresent(tool))
        #expect(intros.shouldPresent(entry("emoji")))
    }

    @Test func skipAllSilencesEveryTool() {
        let intros = store()
        intros.skipAll(current: "clipboard")
        #expect(!intros.enabled)
        #expect(!intros.shouldPresent(entry("emoji")))
        #expect(intros.seen == ["clipboard"])
    }

    @Test func disabledSettingSuppressesIntroductions() {
        let intros = store()
        intros.enabled = false
        #expect(!intros.shouldPresent(entry()))
        intros.enabled = true
        #expect(intros.shouldPresent(entry()))
    }

    @Test func resetRestoresEverything() {
        let intros = store()
        intros.skipAll(current: "clipboard")
        intros.markSeen("emoji")
        intros.defaults.set(true, forKey: HostSettingsCatalog.getStartedDismissedKey)
        intros.reset()
        #expect(intros.enabled)
        #expect(intros.seen.isEmpty)
        #expect(!intros.defaults.bool(forKey: HostSettingsCatalog.getStartedDismissedKey))
        #expect(intros.shouldPresent(entry()))
    }

    @Test func toolsWithoutAGuideNeverPresent() {
        let intros = store()
        #expect(!intros.shouldPresent(entry(guide: false)))
        #expect(!intros.shouldPresent(nil))
    }

    @Test func seenStateRoundTrips() {
        let ids: Set<String> = ["a", "b", "c"]
        #expect(HostIntroductions.decode(HostIntroductions.encode(ids)) == ids)
        #expect(HostIntroductions.decode("").isEmpty)
    }

    private func input(
        done: Bool = false, known: Bool = true, missing: Int = 0, downloads: Bool = false,
        tried: Bool = false, agent: Bool = false, dismissed: Bool = false
    ) -> HostGetStarted {
        HostGetStarted(
            .init(
                onboardingCompleted: done, permissionsKnown: known, missingPermissions: missing,
                hasDownloads: downloads, triedTool: tried, agentConnected: agent,
                dismissed: dismissed))
    }

    @Test func getStartedTracksEachStep() {
        let fresh = input(missing: 2)
        #expect(fresh.visible)
        #expect(fresh.completed == 0)
        let progressed = input(done: true, downloads: true)
        #expect(progressed.completed == 3)
        #expect(progressed.step(.permissions)?.done == true)
        #expect(progressed.step(.tryTool)?.done == false)
        #expect(progressed.visible)
    }

    @Test func getStartedOrdersInstallBeforePermissionsAndPointsAtTheNextStep() {
        let fresh = input(missing: 0)
        #expect(fresh.steps.map(\.kind) == [.setup, .install, .permissions, .tryTool, .agent])
        #expect(fresh.next == .setup)
        #expect(fresh.progress == "1 of 5 done")
        #expect(input(done: true).next == .install)
        #expect(input(done: true, missing: 1, downloads: true).next == .permissions)
        #expect(input(done: true, downloads: true, tried: true, agent: true).next == nil)
    }

    @Test func getStartedHidesWhenDoneDismissedOrUnknown() {
        let complete = input(done: true, downloads: true, tried: true, agent: true)
        #expect(complete.finished && !complete.visible)
        #expect(!input(dismissed: true).visible)
        #expect(!input(known: false).visible)
        #expect(input(known: false).step(.permissions)?.done == false)
    }

    @Test func suiteSummaryCountsInstalledAndAvailable() {
        let tools = [entry("a"), entry("b"), entry("c")]
        #expect(HostSuiteLandingSummary.summary(tools, downloaded: []) == "3 available to get")
        #expect(
            HostSuiteLandingSummary.summary(tools, downloaded: ["a"])
                == "1 installed, 2 available to get")
        #expect(
            HostSuiteLandingSummary.summary(tools, downloaded: ["a", "b", "c"])
                == "All 3 installed")
        #expect(HostSuiteLandingSummary.tagline(tools[0]) == "t")
        #expect(HostSuiteLandingSummary.badge(installed: true, active: true, pending: false) == nil)
        #expect(HostSuiteLandingSummary.badge(installed: true, active: false, pending: false) == "Off")
        #expect(HostSuiteLandingSummary.badge(installed: false, active: false, pending: false) == nil)
        #expect(
            HostSuiteLandingSummary.badge(installed: true, active: false, pending: true)
                == "Cleaning up")
    }
}
