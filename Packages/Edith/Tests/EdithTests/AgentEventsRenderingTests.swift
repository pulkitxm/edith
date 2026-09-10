import AppKit
import EdithKit
import SwiftUI
import Testing

@testable import Edith

@MainActor
@Suite(.serialized) struct AgentEventsRenderingTests {
    @Test func timelineRendersSyntheticEventsAndLoadingStates() throws {
        let model = AgentEventsModel()
        let anchor = Date(timeIntervalSince1970: 1_783_512_000)
        model.receive(
            (0..<150).map { index in
                AgentEvent(
                    date: anchor.addingTimeInterval(Double(index) * 15),
                    level: index.isMultiple(of: 7) ? .warning : .info,
                    category: "sample.jobs",
                    name: index.isMultiple(of: 7) ? "job.deferred" : "job.completed",
                    message: index.isMultiple(of: 7)
                        ? "Sample archive refresh will resume when external power is available."
                        : "Sample workspace inventory refreshed successfully.",
                    duration: index.isMultiple(of: 7) ? nil : 0.24)
            })
        for scheme in [ColorScheme.light, .dark] {
            try render(
                AgentEventsScreen(model: model), name: "agent-events-\(scheme)", scheme: scheme)
            try render(
                AgentEventsScreen(model: model), name: "agent-events-compact-\(scheme)",
                scheme: scheme, size: CGSize(width: 680, height: 460))
            try render(
                AgentEventRow(
                    event: AgentEvent(
                        level: .warning, category: "sample.archive", name: "Archive deferred",
                        message: "The sample archive will resume when this Mac connects to power.",
                        taskID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")),
                    expanded: true
                )
                .disclosureGroupStyle(EdithDisclosureGroupStyle())
                .padding(24)
                .edithSurface()
                .padding(20),
                name: "agent-event-expanded-\(scheme)", scheme: scheme,
                size: CGSize(width: 840, height: 260))
        }
        try render(AgentEventsScreen(), name: "agent-events-loading")
        model.filter(search: "missing", errorsOnly: true)
        try render(AgentEventsScreen(model: model), name: "agent-events-empty")
        try render(BackgroundAgentPane(), name: "agent-settings-loading")
    }

    @Test func appSurfacesRenderWithSyntheticData() async throws {
        let name = "com.pulkit.edith.tests.surfaces.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let model = DashboardModel(preferences: defaults)
        let daily: [[String: Any]] = (1...7).map { day in
            [
                "period": "2026-07-0\(day)",
                "bySource": [
                    "sample": [
                        [
                            "modelName": "sample-model", "inputTokens": 180_000 * day,
                            "outputTokens": 24_000 * day, "cacheCreationTokens": 12_000,
                            "cacheReadTokens": 48_000, "cost": Double(day) * 0.7,
                        ]
                    ]
                ],
            ]
        }
        let document: [String: Any] = [
            "schemaVersion": 4, "generatedAt": "2026-07-07T12:00:00Z",
            "sources": ["sample"], "defaultSources": ["sample"],
            "sourceMeta": ["sample": ["label": "Sample agent"]], "daily": daily,
        ]
        model.ingest(
            try JSONDecoder().decode(
                DashUsage.self, from: JSONSerialization.data(withJSONObject: document)))
        await model.awaitPendingComputation()
        let agent = BackgroundAgentModel()
        agent.registration = .enabled
        agent.loading = false
        agent.tasksLoading = false
        agent.runtime = AgentRuntimeSnapshot(
            build: "sample", startedAt: Date().addingTimeInterval(-3600), processIdentifier: 1234,
            residentBytes: 32_000_000, cpuPercent: 0.2, subscriberCount: 2,
            storePath: "/sample/agent.sqlite", schemaVersion: 1)
        agent.jobs = [
            AgentJobSnapshot(
                descriptor: AgentJobDescriptor(
                    id: "sample.refresh", title: "Workspace refresh", trigger: .timer,
                    cadence: .every(ambient: 300, live: 30)),
                phase: .idle, subscribers: 0, lastRun: Date().addingTimeInterval(-60),
                lastDuration: 0.24, lastError: nil, runCount: 12)
        ]
        for scheme in [ColorScheme.light, .dark] {
            try render(
                DashboardView(model: model), name: "dashboard-\(scheme)", scheme: scheme,
                size: CGSize(width: 1180, height: 820))
            try render(
                BackgroundAgentPane(model: agent), name: "agent-settings-\(scheme)", scheme: scheme,
                size: CGSize(width: 680, height: 760))
        }
    }

    private func render(
        _ view: some View, name: String, scheme: ColorScheme = .light,
        size: CGSize = CGSize(width: 840, height: 620)
    ) throws {
        let host = NSHostingView(
            rootView:
                view
                .environment(\.automaticViewActionsEnabled, false)
                .environment(\.colorScheme, scheme)
                .background(Color(nsColor: .windowBackgroundColor)))
        host.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        host.frame = NSRect(origin: .zero, size: size)
        let window = TestWindowHost.window(contentRect: host.frame)
        defer { window.orderOut(nil) }
        window.contentView = host
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        #expect(bitmap.pixelsWide > 0)
        #expect(bitmap.pixelsHigh > 0)
        if let directory = ProcessInfo.processInfo.environment["EDITH_EVIDENCE_DIR"] {
            let destination = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(
                at: destination, withIntermediateDirectories: true)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: destination.appendingPathComponent("\(name).png"))
        }
    }
}
