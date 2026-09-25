import Foundation
import Testing

@testable import EdithKit

@Suite struct AttentionAnalyzerTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func app(
        _ bundleID: String, _ name: String, at offset: TimeInterval, for duration: TimeInterval,
        title: String? = nil, tags: [String: String]? = nil, presence: AttentionPresence = .active
    ) -> AttentionEvent {
        AttentionEvent(
            startedAt: start.addingTimeInterval(offset), duration: duration, source: .application,
            presence: presence, appName: name, bundleID: bundleID, windowTitle: title, tags: tags)
    }

    private func summary(
        _ events: [AttentionEvent], settings: AttentionSettings = AttentionSettings(),
        classifications: AttentionClassifications = .init(), length: TimeInterval = 7_200
    ) -> AttentionSummary {
        AttentionAnalyzer(calendar: calendar).summary(
            events: events, settings: settings, classifications: classifications, from: start,
            to: start.addingTimeInterval(length))
    }

    @Test func theCatalogClassifiesCommonDeveloperTools() {
        var classifier = AttentionClassifier(settings: AttentionSettings())
        let xcode = classifier.classify(app("com.apple.dt.Xcode", "Xcode", at: 0, for: 1))
        #expect(xcode.categoryID == "coding")
        #expect(xcode.source == .catalog)
        let docs = classifier.classify(
            AttentionEvent(
                startedAt: start, duration: 1, source: .browser, appName: "Chrome",
                domain: "docs.google.com"))
        #expect(docs.categoryID == "writing")
        let search = classifier.classify(
            AttentionEvent(
                startedAt: start, duration: 1, source: .browser, appName: "Chrome",
                domain: "www.google.com"))
        #expect(search.categoryID == "neutral")
        #expect(search.entityID == "web:google.com")
    }

    @Test func productsUnifyTheirAppAndWebsite() {
        var classifier = AttentionClassifier(settings: AttentionSettings())
        let native = classifier.classify(app("net.whatsapp.WhatsApp", "WhatsApp", at: 0, for: 1))
        let web = classifier.classify(
            AttentionEvent(
                startedAt: start, duration: 1, source: .browser, appName: "Chrome",
                domain: "web.whatsapp.com"))
        #expect(native.entityID == web.entityID)
        #expect(native.entityName == "WhatsApp")
    }

    @Test func userRulesBeatTheCatalogAndSpecificRulesBeatBroadOnes() {
        var settings = AttentionSettings()
        settings.rules = [
            AttentionIdentityRule(name: "Video", categoryID: "learning", domains: ["youtube.com"]),
            AttentionIdentityRule(
                name: "Swift talks", categoryID: "coding", domains: ["youtube.com"],
                keywords: ["swift"]),
        ]
        var classifier = AttentionClassifier(settings: settings)
        func page(_ title: String) -> AttentionEvent {
            AttentionEvent(
                startedAt: start, duration: 1, source: .browser, appName: "Chrome",
                windowTitle: title, domain: "www.youtube.com")
        }
        #expect(classifier.classify(page("Lofi beats")).categoryID == "learning")
        #expect(classifier.classify(page("Swift concurrency deep dive")).categoryID == "coding")
    }

    @Test func edithContextDecidesTheCategoryOfTimeInsideEdith() {
        var classifier = AttentionClassifier(settings: AttentionSettings())
        let sessions = classifier.classify(
            app("com.pulkit.edith", "Edith", at: 0, for: 1, tags: ["page": "herdr"]))
        let music = classifier.classify(
            app("com.pulkit.edith", "Edith", at: 0, for: 1, tags: ["page": "music"]))
        #expect(sessions.categoryID == "agents")
        #expect(music.categoryID == "music")
        #expect(sessions.entityID == music.entityID)
    }

    @Test func jevDecisionsFillGapsButNeverOverrideRules() {
        let decisions = AttentionClassifications(
            entities: [
                "app:com.example.Unknown": AttentionJevDecision(
                    categoryID: "design", confidence: 0.8),
                "app:com.apple.dt.Xcode": AttentionJevDecision(
                    categoryID: "games", confidence: 0.99),
            ],
            titles: [
                AttentionClassifications.titleKey(
                    entityID: "web:youtube.com", title: "(3) Building a compiler"):
                    AttentionJevDecision(categoryID: "learning", confidence: 0.9)
            ])
        var classifier = AttentionClassifier(
            settings: AttentionSettings(), classifications: decisions)
        let unknown = classifier.classify(app("com.example.Unknown", "Mystery", at: 0, for: 1))
        #expect(unknown.categoryID == "design")
        #expect(unknown.source == .jev)
        #expect(classifier.classify(app("com.apple.dt.Xcode", "Xcode", at: 0, for: 1)).categoryID == "coding")
        let video = classifier.classify(
            AttentionEvent(
                startedAt: start, duration: 1, source: .browser, appName: "Chrome",
                windowTitle: "(5) Building a compiler", domain: "youtube.com"))
        #expect(video.categoryID == "learning")
    }

    @Test func flickersDoNotCountAsContextSwitches() {
        let events = [
            app("com.apple.dt.Xcode", "Xcode", at: 0, for: 60),
            app("com.tinyspeck.slackmacgap", "Slack", at: 60, for: 3),
            app("com.apple.dt.Xcode", "Xcode", at: 63, for: 60),
            app("com.tinyspeck.slackmacgap", "Slack", at: 123, for: 40),
            app("com.apple.dt.Xcode", "Xcode", at: 163, for: 40),
        ]
        let result = summary(events)
        #expect(result.contextSwitches == 2)
        #expect(result.transitions.first { $0.from == "Xcode" }?.to == "Slack")
        #expect(result.activeDuration == 203)
    }

    @Test func focusBlocksTolerateShortInterruptions() {
        let events = [
            app("com.apple.dt.Xcode", "Xcode", at: 0, for: 900),
            app("com.tinyspeck.slackmacgap", "Slack", at: 900, for: 90),
            app("com.apple.dt.Xcode", "Xcode", at: 990, for: 900),
            app("com.tinyspeck.slackmacgap", "Slack", at: 1_890, for: 600),
            app("com.apple.dt.Xcode", "Xcode", at: 2_490, for: 600),
        ]
        let result = summary(events, length: 7_200)
        #expect(result.focusBlocks.count == 1)
        #expect(result.focusBlocks.first?.focused == 1_800)
        #expect(result.focusBlocks.first?.interruptions == 1)
        #expect(result.focusBlocks.first?.end == start.addingTimeInterval(1_890))
    }

    @Test func dimensionsBreakDownEdithTimeByMachineAndAgent() {
        let events = [
            app(
                "com.pulkit.edith", "Edith", at: 0, for: 300,
                tags: ["page": "herdr", "machine": "tuf", "agent": "Codex"]),
            app(
                "com.pulkit.edith", "Edith", at: 300, for: 200,
                tags: ["page": "herdr", "machine": "This Mac", "agent": "Claude Code"]),
        ]
        let result = summary(events)
        let machines = result.dimension(AttentionTag.machine)?.rows ?? []
        #expect(machines.map(\.key) == ["tuf", "This Mac"])
        #expect(machines.first?.duration == 300)
        #expect(result.dimension(AttentionTag.agent)?.total == 500)
        #expect(result.entities.count == 1)
        #expect(result.entities.first?.visits == 1)
    }

    @Test func agentIntervalsReportWorkPerMachineAndPeakConcurrency() {
        func agent(
            _ id: String, machine: String, kind: String, at offset: TimeInterval,
            for duration: TimeInterval, status: String = "working"
        ) -> AttentionEvent {
            AttentionEvent(
                id: "agent:\(id):\(offset)", startedAt: start.addingTimeInterval(offset),
                duration: duration, source: .agent, windowTitle: "Task \(id)",
                tags: [
                    "machine": machine, "agent": kind, "session": id, "status": status,
                    "project": "edith",
                ])
        }
        let events = [
            agent("a", machine: "tuf", kind: "Codex", at: 0, for: 3_600),
            agent("b", machine: "tuf", kind: "Claude Code", at: 1_800, for: 1_800),
            agent("c", machine: "This Mac", kind: "Codex", at: 0, for: 600, status: "blocked"),
            app(
                "com.pulkit.edith", "Edith", at: 0, for: 120,
                tags: ["page": "herdr", "machine": "tuf", "agent": "Codex"]),
        ]
        let result = summary(events).agents
        #expect(result.working == 5_400)
        #expect(result.blocked == 600)
        #expect(result.peakConcurrent == 2)
        #expect(result.machines.first?.key == "tuf")
        #expect(result.machines.first?.sessions == 2)
        #expect(result.machines.first?.attended == 120)
        #expect(result.kinds.first { $0.key == "Codex" }?.working == 3_600)
        #expect(result.sessions.count == 3)
        #expect(!result.concurrency.isEmpty)
    }

    @Test func lockScreenAppsAndIgnoredAppsNeverCountAsActive() {
        var settings = AttentionSettings()
        settings.ignoredBundleIDs = ["com.example.Private"]
        let events = [
            app("com.apple.loginwindow", "loginwindow", at: 0, for: 100),
            app("com.example.Private", "Private", at: 100, for: 100),
            app("com.apple.dt.Xcode", "Xcode", at: 200, for: 100),
        ]
        let result = summary(events, settings: settings)
        #expect(result.activeDuration == 100)
        #expect(result.idleDuration == 100)
    }

    @Test func daysAndHoursSplitIntervalsAtBoundaries() {
        let midnight = calendar.startOfDay(for: start).addingTimeInterval(86_400)
        let offset = midnight.timeIntervalSince(start) - 1_800
        let events = [app("com.apple.dt.Xcode", "Xcode", at: offset, for: 3_600)]
        let result = AttentionAnalyzer(calendar: calendar).summary(
            events: events, settings: AttentionSettings(), from: start,
            to: midnight.addingTimeInterval(3_600))
        #expect(result.days.count == 2)
        #expect(result.days.map(\.active) == [1_800, 1_800])
        #expect(result.hours.count == 2)
        #expect(result.kinds["focus"] == 3_600)
    }

    @Test func signalsAreClippedProportionallyAndSummed() {
        var event = app("com.apple.dt.Xcode", "Xcode", at: -50, for: 100)
        event.signals = AttentionSignals(keys: 100, clicks: 10, scrolls: 0)
        let clipped = event.clipped(from: start, to: start.addingTimeInterval(1_000))
        #expect(clipped?.signals?.keys == 50)
        #expect(clipped?.signals?.clicks == 5)
    }

    @Test func legacySettingsGainTheNewCategoriesWithoutLosingRules() throws {
        let legacy = """
            {"enabled":true,"trackingEnabled":true,"browserTrackingEnabled":false,
            "idleThreshold":300,"privacyLevel":"domains","windowTitlesEnabled":false,
            "iCloudBackupEnabled":false,"serverPort":52728,"serverToken":"t",
            "categories":[{"id":"focus","name":"Deep","kind":"focus","color":"000000"}],
            "rules":[{"id":"r","name":"Edith","categoryID":"focus","bundleIDs":["com.pulkit.edith"],"domains":[]}]}
            """
        let settings = try JSONDecoder().decode(AttentionSettings.self, from: Data(legacy.utf8))
        #expect(settings.categories.first?.name == "Deep")
        #expect(settings.categories.contains { $0.id == "agents" })
        #expect(settings.rules.first?.keywords == [])
        #expect(settings.agentTrackingEnabled)
    }
}
