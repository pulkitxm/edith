import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import SwiftUI
import Testing
import Vision

@testable import UsageExtension

@MainActor @Suite("UsageDashboardCaptureTests", .serialized)
struct UsageDashboardCaptureTests {
    enum Fixture: String, CaseIterable {
        case firstRun = "first-run"
        case collecting
        case loading
        case failed
        case populated
        case notice
    }

    struct Variant {
        let name: String
        let size: CGSize
        let scheme: ColorScheme
        var zoom = 1.0
    }

    static let variants = [
        Variant(name: "regular-light", size: CGSize(width: 1100, height: 760), scheme: .light),
        Variant(name: "regular-dark", size: CGSize(width: 1100, height: 760), scheme: .dark),
        Variant(name: "compact-light", size: CGSize(width: 640, height: 700), scheme: .light),
        Variant(name: "compact-dark", size: CGSize(width: 640, height: 700), scheme: .dark),
    ]

    static let zoomed = Variant(
        name: "zoom-1.6", size: CGSize(width: 1100, height: 760), scheme: .light, zoom: 1.6)

    static let expectedText: [Fixture: String] = [
        .firstRun: "See what your coding agents cost",
        .collecting: "Collecting your usage",
        .failed: "Usage could not be read",
        .populated: "Today",
        .notice: "Cost estimates are incomplete",
    ]

    @Test func headerSummaryOmitsMissingPartsAndPluralizes() {
        #expect(
            DashboardView.metaSummary(updated: "", activeDays: 1, sources: "Codex")
                == "1 active day \u{00B7} Codex")
        #expect(
            DashboardView.metaSummary(updated: "5 Nov", activeDays: 3, sources: "")
                == "Updated 5 Nov \u{00B7} 3 active days")
    }

    @Test func activitySummaryFindsBusiestDayAverageAndCurrentStreak() throws {
        let calendar = Calendar(identifier: .gregorian)
        let today = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 10)))
        let day = { (offset: Int, tokens: Double) in
            DayPoint(
                id: "\(offset)", date: calendar.date(byAdding: .day, value: -offset, to: today)!,
                cost: 0, tokens: tokens)
        }
        let summary = UsageActivitySummary.make(
            days: [day(1, 300), day(2, 100), day(3, 0), day(4, 200)], today: today,
            calendar: calendar)
        #expect(summary.streak == 2)
        #expect(summary.busiestTokens == 300)
        #expect(summary.averageTokens == 200)
        #expect(summary.activeDays == 3)
        #expect(UsageActivitySummary.make(days: [day(3, 50)], today: today).streak == 0)
        #expect(UsageActivitySummary.make(days: []) == UsageActivitySummary())
    }

    @Test(arguments: Fixture.allCases)
    func dashboardStatesRenderLegiblyAtEverySize(_ fixture: Fixture) async throws {
        let zoom = UIScale.current
        defer { UIScale.apply(zoom) }
        let extra = fixture == .populated || fixture == .firstRun ? [Self.zoomed] : []
        for variant in Self.variants + extra {
            UIScale.apply(variant.zoom)
            let scene = try await Self.scene(fixture)
            defer { scene.model.shutdown() }
            let lines = try await Self.render(
                scene, variant: variant, name: "\(fixture.rawValue)-\(variant.name)")
            #expect(lines.contains { $0.text.localizedCaseInsensitiveContains("Agent usage") })
            if let expected = Self.expectedText[fixture] {
                #expect(
                    lines.contains { $0.text.localizedCaseInsensitiveContains(expected) },
                    Comment(rawValue: "\(fixture.rawValue) \(variant.name)"))
            }
            if fixture == .populated, variant.zoom == 1, variant.size.width > 1000 {
                try Self.expectFilterRowsShareBaselines(lines, height: variant.size.height)
            }
        }
        if fixture == .populated {
            UIScale.apply(1)
            let scene = try await Self.scene(fixture)
            defer { scene.model.shutdown() }
            let full = Variant(
                name: "full", size: CGSize(width: 1100, height: 2900), scheme: .light)
            let lines = try await Self.render(scene, variant: full, name: "populated-full")
            #expect(lines.contains { $0.text.localizedCaseInsensitiveContains("Agent usage") })
        }
    }

    struct Scene {
        let model: DashboardModel
        let client: UsageUIClient?
    }

    struct Line {
        let text: String
        let box: CGRect
    }

    static func expectFilterRowsShareBaselines(_ lines: [Line], height: CGFloat) throws {
        let range = try #require(lines.first { $0.text == "RANGE" })
        let scope = try #require(lines.first { $0.text == "SCOPE" })
        let subtitle = try #require(lines.first { $0.text.hasPrefix("Updated") })
        #expect((subtitle.box.minY - range.box.maxY) * height < 32)
        let today = try #require(lines.first { $0.text.hasPrefix("Today") })
        #expect(abs(range.box.minY - today.box.minY) * height < 3)
        #expect(scope.box.minY < range.box.minY)
        #expect(abs(range.box.minX - scope.box.minX) * 1100 < 2)
    }

    static func scene(_ fixture: Fixture) async throws -> Scene {
        let suite = "usage-capture-" + UUID().uuidString
        let preferences = try #require(UserDefaults(suiteName: suite))
        preferences.removePersistentDomain(forName: suite)
        let model = DashboardModel(
            preferences: preferences,
            homeUsageStore: HomeUsageSnapshotStore(
                file: FileManager.default.temporaryDirectory.appendingPathComponent(
                    "\(suite)/home-usage.json")))
        switch fixture {
        case .loading:
            _ = model.contentLoad.begin()
        case .firstRun:
            model.contentLoad.complete(model.contentLoad.begin(), empty: true)
        case .collecting:
            model.contentLoad.complete(model.contentLoad.begin(), empty: true)
        case .failed:
            model.contentLoad.fail(
                model.contentLoad.begin(),
                message: "The usage history file is not valid JSON.")
        case .populated, .notice:
            model.ingest(try JSONDecoder().decode(DashUsage.self, from: populatedDocument()))
            await model.awaitPendingComputation()
        }
        guard fixture == .notice else { return Scene(model: model, client: nil) }
        let client = UsageUIClient { command, _ in
            switch command {
            case "usage.status":
                return try JSONSerialization.data(withJSONObject: [
                    "refreshing": false,
                    "notice":
                        "Cost estimates are incomplete for 2 unpriced models. Token totals include this usage.",
                ])
            default:
                return Data("{}".utf8)
            }
        }
        try await client.refreshState()
        return Scene(model: model, client: client)
    }

    static func render(_ scene: Scene, variant: Variant, name: String) async throws -> [Line] {
        let compact = variant.size.width < UIScale.pt(720)
        let view = DashboardView(model: scene.model, client: scene.client)
            .environment(\.usageUIClient, scene.client)
            .environment(\.automaticViewActionsEnabled, false)
            .environment(\.compactLayout, compact)
            .environment(\.colorScheme, variant.scheme)
            .transaction { $0.animation = nil }
        let (window, host) = UsageScrollHarness.host(view, size: variant.size)
        defer { window.orderOut(nil) }
        host.appearance = NSAppearance(named: variant.scheme == .dark ? .darkAqua : .aqua)
        if name.hasPrefix("collecting") { UsageEvents.post(UsageEvents.refreshStarted) }
        defer { if name.hasPrefix("collecting") { UsageEvents.post(UsageEvents.refreshFinished) } }
        await UsageScrollHarness.settle(host, for: .milliseconds(600))
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        #expect(png.count > 1_000)
        if let root = ProcessInfo.processInfo.environment["EDITH_TEST_CAPTURE_SURFACES"] {
            let directory = URL(fileURLWithPath: root)
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            try png.write(to: directory.appendingPathComponent("usage-\(name).png"))
        }
        let recognition = VNRecognizeTextRequest()
        recognition.recognitionLevel = .accurate
        recognition.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: #require(bitmap.cgImage)).perform([recognition])
        return (recognition.results ?? []).compactMap { result in
            result.topCandidates(1).first.map { Line(text: $0.string, box: result.boundingBox) }
        }
    }

    static func populatedDocument() throws -> Data {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let models = [
            ("claude-sonnet-sample", 3.0), ("gpt-sample-codex", 1.4), ("claude-haiku-sample", 0.4),
        ]
        let sources = ["claude-code", "codex"]
        let projects = ["sample-api", "sample-web", "sample-cli"]
        var days: [[String: Any]] = []
        for offset in 0..<84 {
            guard offset % 7 != 5,
                let date = calendar.date(byAdding: .day, value: -offset, to: today)
            else { continue }
            let wave = 0.55 + 0.45 * sin(Double(offset) / 4.0)
            var bySource: [String: [[String: Any]]] = [:]
            for (sourceIndex, source) in sources.enumerated() {
                bySource[source] = models.enumerated().compactMap { index, entry in
                    guard (index + sourceIndex) % 3 != 2 else { return nil }
                    let input = (1_200_000 + Double(index) * 400_000) * wave
                    return [
                        "modelName": entry.0, "inputTokens": input,
                        "outputTokens": input * 0.18, "cacheReadTokens": input * 2.4,
                        "cacheCreationTokens": input * 0.3,
                        "cost": entry.1 * wave * (sourceIndex == 0 ? 4 : 2),
                    ]
                }
            }
            let hours: [[String: Any]] = (0..<24).map { hour in
                let active = (9...19).contains(hour)
                return [
                    "tokens": active ? 380_000 * wave * Double(1 + hour % 4) : 0,
                    "cost": active ? 0.6 * wave * Double(1 + hour % 4) : 0,
                ]
            }
            let projectRows: [[String: Any]] = projects.enumerated().map { index, name in
                [
                    "projectName": name, "repositoryName": name,
                    "path": "/Users/sample/code/\(name)",
                    "tokens": 2_400_000 * wave / Double(index + 1),
                    "cost": 5.5 * wave / Double(index + 1),
                    "bySource": [
                        sources[index % 2]: [
                            "tokens": 2_400_000 * wave / Double(index + 1),
                            "cost": 5.5 * wave / Double(index + 1),
                        ]
                    ],
                ]
            }
            days.append([
                "period": DashboardModel.ymd.string(from: date), "bySource": bySource,
                "hours": hours, "projects": projectRows,
            ])
        }
        return try JSONSerialization.data(withJSONObject: [
            "sources": sources, "defaultSources": sources,
            "sourceMeta": [
                "claude-code": ["label": "Claude Code"], "codex": ["label": "Codex"],
            ],
            "generatedAt": ISO8601DateFormatter().string(from: Date()),
            "sessions": [], "daily": days,
        ])
    }
}
