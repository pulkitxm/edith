import Foundation
import Testing

@testable import EdithCLI
@testable import EdithKit

@Suite struct AttentionContextRuleTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func specificURLsOverrideProfileRulesAndReportSeparateTotals() {
        let settings = AttentionSettings(rules: [
            AttentionIdentityRule(
                id: "work", name: "Work calls", categoryID: "meetings",
                domains: ["calls.example.com"], browserProfiles: ["Work"],
                reportSeparately: true, productivity: .veryProductive, sphere: .work),
            AttentionIdentityRule(
                id: "social", name: "Social call", categoryID: "social",
                domains: ["calls.example.com"], urls: ["calls.example.com/social"],
                reportSeparately: true, productivity: .veryDistracting, sphere: .personal),
        ])
        let events = ["social", "planning"].enumerated().map { index, path in
            AttentionEvent(
                startedAt: start.addingTimeInterval(Double(index) * 60), duration: 60,
                source: .browser, appName: "Browser", url: "https://calls.example.com/\(path)",
                domain: "calls.example.com", browserProfile: "Work")
        }
        let summary = AttentionAnalyzer().summary(
            events: events, settings: settings, from: start, to: start.addingTimeInterval(120))
        #expect(summary.activeDuration == 120)
        #expect(summary.entities.first { $0.id == "rule:social" }?.duration == 60)
        #expect(summary.entities.first { $0.id == "rule:work" }?.productivity == .veryProductive)
        #expect(summary.dimensions.first { $0.key == "profile" }?.rows.first?.duration == 120)
    }

    @Test func profileIsPartOfTheCacheKeyAndDoesNotMatchAnotherProfile() {
        var classifier = AttentionClassifier(
            settings: AttentionSettings(rules: [
                AttentionIdentityRule(
                    name: "Work", categoryID: "coding", domains: ["example.com"],
                    browserProfiles: ["Work"])
            ]))
        var event = AttentionEvent(
            startedAt: start, duration: 60, source: .browser, domain: "example.com",
            browserProfile: "Work")
        #expect(classifier.classify(event).categoryID == "coding")
        event.browserProfile = "Personal"
        #expect(classifier.classify(event).categoryID != "coding")
    }

    @Test func channelRulesCanSplitVideosWithoutChangingTheSiteDefault() {
        var classifier = AttentionClassifier(
            settings: AttentionSettings(rules: [
                AttentionIdentityRule(
                    name: "Video", categoryID: "entertainment", domains: ["video.example.com"]),
                AttentionIdentityRule(
                    id: "tutorials", name: "Tutorials", categoryID: "learning",
                    domains: ["video.example.com"], contexts: ["channel=Example teacher"],
                    reportSeparately: true, productivity: .veryProductive),
            ]))
        var event = AttentionEvent(
            startedAt: start, duration: 60, source: .browser, domain: "video.example.com",
            tags: ["channel": "Example teacher"])
        #expect(classifier.classify(event).entityID == "rule:tutorials")
        event.tags = ["channel": "Other creator"]
        #expect(classifier.classify(event).categoryID == "entertainment")
    }

    @Test func rulesForAppsWithoutBundleIDsUseTheirRecordedNames() {
        var classifier = AttentionClassifier(
            settings: AttentionSettings(rules: [
                AttentionIdentityRule(
                    name: "Preview tool", categoryID: "coding", bundleIDs: ["Preview tool"])
            ]))
        let event = AttentionEvent(
            startedAt: start, duration: 60, source: .application, appName: "Preview tool")
        #expect(classifier.classify(event).categoryID == "coding")
    }

    @Test func importMergesByIDAndRejectsInvalidDocumentsBeforeSaving() throws {
        let rule = AttentionIdentityRule(
            id: "example", name: "Example", categoryID: "learning", domains: ["example.com"])
        let document = AttentionRuleDocument(categories: [], rules: [rule])
        let first = try document.applying(to: AttentionSettings())
        let second = try document.applying(to: first)
        #expect(second.rules.count == 1)
        var invalid = rule
        invalid.categoryID = "missing"
        #expect(throws: (any Error).self) {
            try AttentionRuleDocument(categories: [], rules: [invalid]).applying(to: first)
        }
    }
}
