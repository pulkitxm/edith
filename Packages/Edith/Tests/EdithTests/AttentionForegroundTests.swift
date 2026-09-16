import Foundation
import Testing

@testable import EdithKit

@Suite struct AttentionForegroundTests {
    let now = Date(timeIntervalSince1970: 1_775_000_000)
    let settings = AttentionSettings()

    private func dia(start: TimeInterval, duration: TimeInterval, title: String) -> AttentionEvent {
        AttentionEvent(
            startedAt: now.addingTimeInterval(start), duration: duration, source: .application,
            appName: "Dia", bundleID: "company.thebrowser.dia", windowTitle: title)
    }

    private func page(
        start: TimeInterval, duration: TimeInterval, domain: String, title: String, profile: String
    ) -> AttentionEvent {
        AttentionEvent(
            startedAt: now.addingTimeInterval(start), duration: duration, source: .browser,
            appName: "Google Chrome", windowTitle: title, domain: domain, browserProfile: profile)
    }

    private func summary(_ events: [AttentionEvent], seconds: TimeInterval) -> AttentionSummary {
        AttentionAnalyzer().summary(
            events: events, settings: settings, from: now,
            to: now.addingTimeInterval(seconds))
    }

    @Test func backgroundProfileCannotClaimTimeWhileAnotherProfileIsInFront() {
        let events = [
            dia(start: 0, duration: 60, title: "Personal: Sponsor What D…"),
            page(
                start: 0, duration: 60, domain: "divvsaxena.com",
                title: "Sponsor What Divv Wears", profile: "Default"),
            page(
                start: 0, duration: 60, domain: "orbit.noveum.ai", title: "Standup · Orbit",
                profile: "Work"),
        ]
        let result = summary(events, seconds: 60)
        #expect(result.activeDuration == 60)
        #expect(result.entities.first { $0.name == "divvsaxena.com" }?.duration == 60)
        #expect(result.entities.contains { $0.name == "orbit.noveum.ai" } == false)
    }

    @Test func browserClaimsAreDroppedWhileANonBrowserApplicationIsInFront() {
        let events = [
            AttentionEvent(
                startedAt: now, duration: 60, source: .application, appName: "Slack",
                bundleID: "com.tinyspeck.slackmacgap"),
            page(
                start: 0, duration: 60, domain: "orbit.noveum.ai", title: "Standup · Orbit",
                profile: "Work"),
        ]
        let result = summary(events, seconds: 60)
        #expect(result.activeDuration == 60)
        #expect(result.entities.count == 1)
        #expect(result.entities.first?.name == "Slack")
        #expect(result.entities.contains { $0.name == "orbit.noveum.ai" } == false)
    }

    @Test func contestedClaimsFallBackToTheApplicationWhenNoTitleCorroborates() {
        let events = [
            dia(start: 0, duration: 60, title: "Personal: Inbox"),
            page(
                start: 0, duration: 60, domain: "orbit.noveum.ai", title: "Standup · Orbit",
                profile: "Work"),
            page(
                start: 0, duration: 60, domain: "news.example", title: "Front page",
                profile: "Default"),
        ]
        let result = summary(events, seconds: 60)
        #expect(result.activeDuration == 60)
        #expect(result.entities.count == 1)
        #expect(result.entities.first?.name == "Dia")
    }

    @Test func aSingleProfileKeepsItsDetailWhileTheBrowserIsInFront() {
        let events = [
            dia(start: 0, duration: 60, title: "Personal: Standup · Orbit"),
            page(
                start: 10, duration: 30, domain: "orbit.noveum.ai", title: "Standup · Orbit",
                profile: "Work"),
        ]
        let result = summary(events, seconds: 60)
        #expect(result.activeDuration == 60)
        #expect(result.entities.first { $0.name == "orbit.noveum.ai" }?.duration == 30)
        #expect(result.entities.first { $0.name == "Dia" }?.duration == 30)
    }

    @Test func browserOnlyInstallsKeepTheirIntervalsWithoutNativeTracking() {
        let events = [
            page(
                start: 0, duration: 30, domain: "example.com", title: "Example",
                profile: "Default")
        ]
        let result = summary(events, seconds: 60)
        #expect(result.activeDuration == 30)
        #expect(result.entities.first?.name == "example.com")
    }

    @Test func truncatedWindowTitlesStillCorroborateTheForegroundPage() {
        let window = AttentionTitleCorrelation.normalized("Personal: Divv Saxena on…")
        let front = AttentionTitleCorrelation.normalized(
            "Divv Saxena on X: \"I'm selling my body\" / X")
        let background = AttentionTitleCorrelation.normalized("Standup · Orbit")
        #expect(AttentionTitleCorrelation.corroborates(window: window, page: front))
        #expect(AttentionTitleCorrelation.corroborates(window: window, page: background) == false)
    }

    @Test func browserApplicationsAreRecognisedByBundleAndName() {
        #expect(AttentionBrowserIdentity.isBrowser(bundleID: "company.thebrowser.dia", appName: nil))
        #expect(AttentionBrowserIdentity.isBrowser(bundleID: "com.google.Chrome", appName: nil))
        #expect(AttentionBrowserIdentity.isBrowser(bundleID: nil, appName: "Brave Browser"))
        #expect(
            AttentionBrowserIdentity.isBrowser(
                bundleID: "com.tinyspeck.slackmacgap", appName: "Slack") == false)
    }
}
