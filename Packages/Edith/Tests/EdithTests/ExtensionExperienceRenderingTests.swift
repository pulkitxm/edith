import AppKit
import EdithKit
import SwiftUI
import Testing

@testable import Edith

@MainActor
@Suite(.serialized) struct ExtensionExperienceRenderingTests {
    @Test func analyticsContentRendersAtCompactZoomAndRegularWidths() async throws {
        let agent = CodeStatsFakeAgent(status: CodeStatsPageFixture.status())
        agent.facts = CodeStatsFactBuilder.build(
            commits: (0..<1000).map { index in
                CodeStatsCommit(
                    sha: "sample-\(index)", day: "2026-10-0\(index % 5 + 1)", hour: index % 24,
                    repository: "sample/project-\(index % 150)",
                    languages: ["Swift": .init(added: 10 + index % 40)])
            })
        let code = CodeStatsModel(
            service: agent.service, defaults: StudioTestFiles.defaults(),
            calendar: CodeStatsPageFixture.calendar,
            today: { CodeStatsPageFixture.date("2026-10-05") })
        await code.refresh()
        await code.select(.all)
        await code.updateFilter { $0.includeBulk = true }
        await code.toggleLanguage("Swift")
        let usage = try usageModel()
        let root = try StudioTestFiles.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = AttentionRepository(root: root)
        try repository.saveSettings(AttentionSettings(isEnabled: true, trackingEnabled: true))
        let start = Calendar.current.startOfDay(for: Date()).addingTimeInterval(-86_400)
        for index in 0..<200 {
            try repository.append(
                AttentionEvent(
                    startedAt: start.addingTimeInterval(Double(index) * 120), duration: 60,
                    source: .application, appName: "Sample editor", bundleID: "org.example.editor",
                    windowTitle: "Sample workspace \(index)"), pulseTime: 0)
        }
        let attention = AttentionPageModel(repository: repository)
        attention.section = .breakdown
        attention.breakdownDimension = AttentionDimension.title
        attention.select(.yesterday)
        attention.reload()
        await attention.waitForReload()
        #expect(attention.breakdown.rows.count == 200)
        let previous = UIScale.current
        defer { UIScale.apply(previous) }
        for (width, zoom) in [(1280.0, 1.0), (680.0, 1.5)] {
            UIScale.apply(zoom)
            for scheme in [ColorScheme.light, .dark] {
                for (name, view) in [
                    ("code-stats", AnyView(CodeStatsPage(model: code))),
                    ("attention", AnyView(AttentionPage(model: attention))),
                    ("agent-usage", AnyView(DashboardView(model: usage))),
                ] {
                    let host = NSHostingView(
                        rootView:
                            view
                            .environment(\.compactLayout, width < 900)
                            .environment(\.colorScheme, scheme)
                            .environment(\.automaticViewActionsEnabled, false)
                            .environment(\.loadingAnimationsEnabled, false))
                    host.frame = NSRect(x: 0, y: 0, width: width, height: 950)
                    let window = TestWindowHost.window(contentRect: host.frame)
                    window.contentView = host
                    window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                    window.orderBack(nil)
                    defer { window.orderOut(nil) }
                    try await Task.sleep(for: .milliseconds(250))
                    host.layoutSubtreeIfNeeded()
                    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    let png = try #require(bitmap.representation(using: .png, properties: [:]))
                    #expect(png.count > 10_000)
                    if let directory = ProcessInfo.processInfo.environment[
                        "EDITH_TEST_EVIDENCE_DIR"]
                    {
                        let folder = URL(fileURLWithPath: directory)
                        try FileManager.default.createDirectory(
                            at: folder, withIntermediateDirectories: true)
                        try png.write(
                            to: folder.appendingPathComponent(
                                "\(name)-content-\(Int(width))-\(scheme).png"))
                    }
                }
            }
        }
    }

    private func usageModel() throws -> DashboardModel {
        let model = DashboardModel(preferences: StudioTestFiles.defaults())
        let daily: [[String: Any]] = (1...5).map { day in
            [
                "period": "2026-10-0\(day)",
                "bySource": [
                    "sample:editor": [
                        [
                            "modelName": "Model Alpha", "inputTokens": day * 1_000_000,
                            "outputTokens": day * 100_000, "cost": Double(day) * 2.5,
                        ]
                    ]
                ],
            ]
        }
        let data = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 8, "generatedAt": "2026-10-05T12:00:00Z",
            "sources": ["sample:editor"], "defaultSources": ["sample:editor"],
            "sourceMeta": ["sample:editor": ["label": "Sample editor", "tool": "Sample editor"]],
            "daily": daily,
        ])
        model.ingest(try JSONDecoder().decode(DashUsage.self, from: data))
        model.range = .all
        return model
    }

}
