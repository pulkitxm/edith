import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Edith
@testable import EdithKit

private struct AttentionSyntheticRandom {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }

    mutating func int(_ range: ClosedRange<Int>) -> Int {
        range.lowerBound + Int(next() % UInt64(range.count))
    }

    mutating func pick<T>(_ values: [T]) -> T { values[int(0...(values.count - 1))] }
}

private enum AttentionSyntheticWeek {
    struct Activity {
        var app: String
        var bundle: String
        var title: String
        var domain: String?
        var path: String?
        var tags: [String: String] = [:]
        var minutes: ClosedRange<Int>
    }

    static let activities: [Activity] = [
        Activity(
            app: "Xcode", bundle: "com.apple.dt.Xcode", title: "OrbitKit · SyncEngine.swift",
            minutes: 12...38),
        Activity(
            app: "Ghostty", bundle: "com.mitchellh.ghostty", title: "swift test · orbit",
            minutes: 4...14),
        Activity(
            app: "Google Chrome", bundle: "com.google.Chrome",
            title: "Fix the sync race · Pull Request #42 · acme/orbit", domain: "github.com",
            path: "/acme/orbit/pull/42", tags: ["repo": "acme/orbit", "section": "pull"],
            minutes: 6...18),
        Activity(
            app: "Google Chrome", bundle: "com.google.Chrome",
            title: "Issues · acme/website", domain: "github.com", path: "/acme/website/issues",
            tags: ["repo": "acme/website", "section": "issues"], minutes: 3...9),
        Activity(
            app: "Edith", bundle: "com.pulkit.edith", title: "Sessions · Refactor the importer",
            tags: [
                "page": "herdr", "machine": "build-box", "agent": "Codex", "project": "orbit",
            ], minutes: 5...16),
        Activity(
            app: "Edith", bundle: "com.pulkit.edith", title: "Sessions · Write the release notes",
            tags: [
                "page": "herdr", "machine": "studio", "agent": "Claude Code",
                "project": "website",
            ], minutes: 3...11),
        Activity(
            app: "Edith", bundle: "com.pulkit.edith", title: "Usage",
            tags: ["page": "dashboard"], minutes: 2...5),
        Activity(
            app: "Slack", bundle: "com.tinyspeck.slackmacgap", title: "#launch · Acme",
            minutes: 2...9),
        Activity(
            app: "WhatsApp", bundle: "net.whatsapp.WhatsApp", title: "WhatsApp", minutes: 1...5),
        Activity(
            app: "Google Chrome", bundle: "com.google.Chrome",
            title: "Swift Charts in depth - YouTube", domain: "www.youtube.com", path: "/watch",
            tags: ["video": "demo1", "section": "watch", "channel": "Swift Talks"],
            minutes: 6...20),
        Activity(
            app: "Google Chrome", bundle: "com.google.Chrome",
            title: "Comedy night special - YouTube", domain: "www.youtube.com", path: "/watch",
            tags: ["video": "demo2", "section": "watch", "channel": "Laugh Club"],
            minutes: 8...26),
        Activity(
            app: "Google Chrome", bundle: "com.google.Chrome", title: "Home / X",
            domain: "x.com", path: "/home", tags: ["section": "home"], minutes: 3...12),
        Activity(
            app: "Google Chrome", bundle: "com.google.Chrome",
            title: "swift charts rectangle mark - Google Search", domain: "www.google.com",
            path: "/search", tags: ["search": "swift charts rectangle mark"], minutes: 1...3),
        Activity(
            app: "Mockly", bundle: "com.example.Mockly", title: "Onboarding flow v3",
            minutes: 4...12),
        Activity(
            app: "Google Chrome", bundle: "com.google.Chrome",
            title: "Roadmap board · Planbase", domain: "planbase.example", path: "/board",
            minutes: 3...8),
    ]

    static func events(days: [Date], seed: UInt64) -> [AttentionEvent] {
        var random = AttentionSyntheticRandom(state: seed)
        var events: [AttentionEvent] = []
        for day in days {
            var cursor = day.addingTimeInterval(9 * 3_600 + Double(random.int(0...40)) * 60)
            let end = day.addingTimeInterval(Double(random.int(18...20)) * 3_600)
            let lunch = day.addingTimeInterval(13 * 3_600)
            var hadLunch = false
            var hadStandup = false
            while cursor < end {
                if !hadStandup, cursor > day.addingTimeInterval(10 * 3_600) {
                    hadStandup = true
                    events += browser(
                        at: cursor, minutes: 22, title: "Meet – Daily Standup",
                        domain: "meet.google.com", path: "/abc-defg-hij", tags: ["section": "call"],
                        random: &random)
                    cursor += 22 * 60
                    continue
                }
                if !hadLunch, cursor > lunch {
                    hadLunch = true
                    events.append(
                        AttentionEvent(
                            startedAt: cursor, duration: 50 * 60, source: .application,
                            presence: .idle, appName: "loginwindow",
                            bundleID: "com.apple.loginwindow"))
                    cursor += 50 * 60
                    continue
                }
                let hour = Calendar.current.component(.hour, from: cursor)
                var pool = activities
                if hour < 17 { pool.removeAll { $0.title.hasPrefix("Comedy") } }
                let activity = random.pick(pool)
                let minutes = random.int(activity.minutes)
                if let domain = activity.domain {
                    events += browser(
                        at: cursor, minutes: minutes, title: activity.title, domain: domain,
                        path: activity.path ?? "/", tags: activity.tags, random: &random)
                } else {
                    events.append(
                        AttentionEvent(
                            startedAt: cursor, duration: Double(minutes) * 60,
                            source: .application, appName: activity.app,
                            bundleID: activity.bundle, windowTitle: activity.title,
                            tags: activity.tags.isEmpty ? nil : activity.tags,
                            signals: signals(minutes: minutes, random: &random)))
                }
                cursor += Double(minutes) * 60 + Double(random.int(0...40))
            }
            events += agents(day: day, random: &random)
            events += music(day: day)
        }
        return events
    }

    static func signals(minutes: Int, random: inout AttentionSyntheticRandom) -> AttentionSignals {
        AttentionSignals(
            keys: minutes * random.int(10...90), clicks: minutes * random.int(2...14),
            scrolls: minutes * random.int(3...30))
    }

    static func browser(
        at start: Date, minutes: Int, title: String, domain: String, path: String,
        tags: [String: String], random: inout AttentionSyntheticRandom
    ) -> [AttentionEvent] {
        let duration = Double(minutes) * 60
        return [
            AttentionEvent(
                startedAt: start, duration: duration, source: .application,
                appName: "Google Chrome", bundleID: "com.google.Chrome",
                windowTitle: "\(title) - Google Chrome - Work"),
            AttentionEvent(
                id: "browser:\(UUID().uuidString)", startedAt: start, duration: duration,
                source: .browser, appName: "Google Chrome", windowTitle: title,
                url: "https://\(domain)\(path)", domain: domain, browserProfile: "Work",
                tags: tags, signals: signals(minutes: minutes, random: &random)),
        ]
    }

    static func agents(day: Date, random: inout AttentionSyntheticRandom) -> [AttentionEvent] {
        let sessions: [(String, String, String, String)] = [
            ("build-box", "Codex", "orbit", "Refactor the importer"),
            ("build-box", "Codex", "orbit", "Add offline sync tests"),
            ("studio", "Claude Code", "website", "Write the release notes"),
            ("This Mac", "Pi", "tools", "Tidy the scripts"),
            ("studio", "OpenCode", "website", "Audit image sizes"),
        ]
        var events: [AttentionEvent] = []
        for (index, session) in sessions.enumerated() {
            var cursor = day.addingTimeInterval(Double(random.int(9...12)) * 3_600)
            for run in 0..<random.int(2...4) {
                let working = Double(random.int(20...95)) * 60
                let tags = [
                    "machine": session.0, "agent": session.1, "project": session.2,
                    "session": "synthetic-\(index)", "status": "working",
                ]
                events.append(
                    AttentionEvent(
                        id: "agent:synthetic-\(index):\(day.timeIntervalSince1970):\(run)",
                        startedAt: cursor, duration: working, source: .agent,
                        appName: session.1, windowTitle: session.3, tags: tags))
                cursor += working
                let waiting = Double(random.int(3...25)) * 60
                var blocked = tags
                blocked["status"] = "blocked"
                events.append(
                    AttentionEvent(
                        id: "agent:synthetic-\(index):\(day.timeIntervalSince1970):\(run):b",
                        startedAt: cursor, duration: waiting, source: .agent,
                        appName: session.1, windowTitle: session.3, tags: blocked))
                cursor += waiting + Double(random.int(10...60)) * 60
            }
        }
        return events
    }

    static func music(day: Date) -> [AttentionEvent] {
        [
            ("Deep Focus", "Ambient Lab", "Spotify", 10.0, 55.0),
            ("Night Drive", "Synth Room", "Spotify", 15.0, 35.0),
            ("Lofi Study Mix", nil, "Edith", 16.5, 40.0),
        ].map { title, artist, service, hour, minutes in
            AttentionEvent(
                id: "media:\(service)-\(title)-\(day.timeIntervalSince1970)",
                startedAt: day.addingTimeInterval(hour * 3_600), duration: minutes * 60,
                source: .media, appName: service,
                media: AttentionMedia(
                    title: title, artist: artist, service: service, kind: "audio", playing: true))
        }
    }
}

@MainActor
@Suite(.serialized) struct AttentionEvidenceTests {
    @Test(
        .enabled(if: ProcessInfo.processInfo.environment["EDITH_ATTENTION_EVIDENCE_DIR"] != nil))
    func theAttentionPageRendersASyntheticWeek() async throws {
        let output = URL(
            fileURLWithPath: try #require(
                ProcessInfo.processInfo.environment["EDITH_ATTENTION_EVIDENCE_DIR"]),
            isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AttentionEvidence.\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = AttentionRepository(root: root)
        let calendar = Calendar.current
        let yesterday = calendar.date(
            byAdding: .day, value: -1, to: calendar.startOfDay(for: Date()))!
        let days = (0..<8).map { calendar.date(byAdding: .day, value: -$0, to: yesterday)! }
        var settings = AttentionSettings(
            isEnabled: true, trackingEnabled: true, browserTrackingEnabled: true)
        settings.rules = [
            AttentionIdentityRule(
                name: "Swift talks", categoryID: "learning", domains: ["youtube.com"],
                keywords: ["swift"])
        ]
        try repository.saveSettings(settings)
        for event in AttentionSyntheticWeek.events(days: days, seed: 42) {
            try repository.append(event, pulseTime: 0)
        }

        let model = AttentionPageModel(repository: repository)
        model.selectRange(from: yesterday, to: yesterday)
        await model.waitForReload()
        #expect(model.summary.activeDuration > 6 * 3_600)
        #expect(!model.summary.agents.isEmpty)
        try render(model, height: 2_330, to: output.appendingPathComponent("overview-day.png"))

        model.section = .timeline
        await model.waitForReload()
        try render(model, height: 1_500, to: output.appendingPathComponent("timeline-day.png"))

        model.section = .breakdown
        model.breakdownDimension = AttentionTag.machine
        await model.waitForReload()
        try render(model, height: 900, to: output.appendingPathComponent("breakdown-machine.png"))

        model.section = .overview
        await model.waitForReload()
        model.selectRange(from: days[6], to: yesterday)
        await model.waitForReload()
        try render(model, height: 2_340, to: output.appendingPathComponent("overview-week.png"))

        model.section = .agents
        await model.waitForReload()
        try render(model, height: 1_240, to: output.appendingPathComponent("agents-week.png"))

        model.section = .breakdown
        model.breakdownDimension = AttentionTag.repository
        await model.waitForReload()
        try render(model, height: 700, to: output.appendingPathComponent("breakdown-repo.png"))
    }

    private func render(_ model: AttentionPageModel, height: CGFloat, to output: URL) throws {
        let host = NSHostingView(
            rootView: AttentionPage(model: model)
                .environment(\.colorScheme, .dark)
                .transaction { $0.animation = nil }
        )
        host.frame = NSRect(x: 0, y: 0, width: 1440, height: height)
        host.appearance = NSAppearance(named: .darkAqua)
        let window = TestWindowHost.window(contentRect: host.frame)
        defer { window.orderOut(nil) }
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        window.orderBack(nil)
        for _ in 0..<3 {
            window.layoutIfNeeded()
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.4))
        }
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: output)
    }
}
