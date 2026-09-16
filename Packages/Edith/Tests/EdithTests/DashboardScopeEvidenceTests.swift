import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Edith
@testable import EdithKit

@MainActor
@Suite(.serialized) struct DashboardScopeEvidenceTests {
    @Test(
        .enabled(
            if: ProcessInfo.processInfo.environment["EDITH_USAGE_RELIABILITY_EVIDENCE_DIR"] != nil))
    func completeScopeRendersTheActualDashboardWithSyntheticMachines() throws {
        let environment = ProcessInfo.processInfo.environment
        let runtime = try #require(environment["EDITH_TEST_RUNTIME_ROOT"])
        let dataRoot = try #require(environment["EDITH_DATA_ROOT"])
        let service = try #require(environment["EDITH_AGENT_MACH_SERVICE"])
        #expect(dataRoot.hasPrefix(runtime + "/"))
        #expect(service != "com.pulkit.edith.agent")
        guard dataRoot.hasPrefix(runtime + "/"), service != "com.pulkit.edith.agent" else { return }
        let output = URL(
            fileURLWithPath: try #require(environment["EDITH_USAGE_RELIABILITY_EVIDENCE_DIR"]),
            isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let suite = "DashboardScopeEvidenceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: AppStorageKeys.Tabs.usageEnabled)
        defaults.set("all", forKey: "dashRange")
        defaults.set("cloud:one", forKey: "dashSources")
        defaults.set("local:one,cloud:one,studio:one", forKey: "dashKnownSources")
        defaults.set(UsageSourceSelection.currentVersion, forKey: "dashSourceSelectionVersion")
        let model = DashboardModel(preferences: defaults)
        model.ingest(try usage())
        #expect(model.series.reduce(0) { $0 + $1.tokens } == 180_000_000)
        try render(model, to: output.appendingPathComponent("dashboard-subset.png"))

        defaults.set("local:one,cloud:one,studio:one", forKey: "dashSources")
        defaults.set("Model Alpha,Model Beta,Model Gamma", forKey: "dashModels")
        defaults.set("", forKey: "dashPaths")
        model.reloadPreferences()
        #expect(model.series.reduce(0) { $0 + $1.tokens } == 750_000_000)
        #expect(model.machineGroups.count == 3)
        #expect(model.machineGroups.allSatisfy { model.machineIsShown($0) })
        try render(model, to: output.appendingPathComponent("dashboard-complete.png"))
    }

    private func render(_ model: DashboardModel, to output: URL) throws {
        let host = NSHostingView(
            rootView: DashboardView(model: model)
                .environment(\.automaticViewActionsEnabled, false)
                .environment(\.companionRequestsEnabled, false)
                .environment(\.machineConnectionsEnabled, false)
                .environment(\.terminalLaunchEnabled, false)
                .environment(\.colorScheme, .dark)
                .transaction { $0.animation = nil }
        )
        host.frame = NSRect(x: 0, y: 0, width: 1440, height: 1040)
        host.appearance = NSAppearance(named: .darkAqua)
        let window = TestWindowHost.window(contentRect: host.frame)
        defer { window.orderOut(nil) }
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        window.orderBack(nil)
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.5))
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        redraw(host)
        #expect(!TestWindowHost.isExposedOnDesktop(window))
        let captureBounds = NSRect(
            x: 0, y: host.isFlipped ? 0 : host.bounds.height - 350,
            width: host.bounds.width, height: 350)
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: captureBounds))
        host.cacheDisplay(in: captureBounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        #expect(data.count > 50_000)
        try data.write(to: output, options: .atomic)
    }

    private func redraw(_ view: NSView) {
        for child in view.subviews { redraw(child) }
        view.needsDisplay = true
        view.displayIfNeeded()
    }

    private func usage() throws -> DashUsage {
        let sources = ["local:one", "cloud:one", "studio:one"]
        let calendar = Calendar(identifier: .gregorian)
        let end = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 12)))
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let daily: [[String: Any]] = try (0..<30).map { offset in
            let date = try #require(calendar.date(byAdding: .day, value: offset - 29, to: end))
            let counts = [16_000_000, 6_000_000, 3_000_000]
            let models = ["Model Alpha", "Model Beta", "Model Gamma"]
            let rows = Dictionary(
                uniqueKeysWithValues: sources.enumerated().map { index, source in
                    (
                        source,
                        [
                            [
                                "modelName": models[index], "inputTokens": counts[index],
                                "outputTokens": 0,
                                "cacheCreationTokens": 0, "cacheReadTokens": 0,
                                "cost": Double(counts[index]) / 1_000_000,
                            ] as [String: Any]
                        ]
                    )
                })
            return ["period": formatter.string(from: date), "bySource": rows]
        }
        let object: [String: Any] = [
            "schemaVersion": 8, "generatedAt": "2026-09-12T12:00:00Z",
            "sources": sources, "defaultSources": sources,
            "sourceMeta": [
                "local:one": ["label": "Tool Alpha", "tool": "Tool Alpha"],
                "cloud:one": [
                    "label": "Tool Beta", "tool": "Tool Beta", "machine": "Cloud Build",
                    "machineID": "11111111-1111-1111-1111-111111111111",
                ],
                "studio:one": [
                    "label": "Tool Gamma", "tool": "Tool Gamma", "machine": "Studio PC",
                    "machineID": "22222222-2222-2222-2222-222222222222",
                ],
            ],
            "daily": daily,
        ]
        return try JSONDecoder().decode(
            DashUsage.self, from: JSONSerialization.data(withJSONObject: object))
    }
}
