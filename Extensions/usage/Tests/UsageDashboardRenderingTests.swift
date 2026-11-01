import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import SwiftUI
import Testing
import Vision
@testable import UsageExtension

@MainActor @Suite(.serialized) struct UsageDashboardRenderingTests {
    @Test func limitsMenuRendersAccountRecoveryAndWeeklyOnlyLimitsAtEverySize() async throws {
        let previousZoom = UIScale.current
        defer { UIScale.apply(previousZoom) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = UsageStore(
            showMenuBar: false, historyURL: root.appendingPathComponent("limits-history.jsonl"))
        defer { store.shutdown() }
        let rejected = ClaudeLimitsReader.Failure.unauthorized.localizedDescription
        let accounts = ["Sample personal", "Sample retired", "Sample current"].enumerated().map {
            index, name in
            ClaudeAccountLimits(
                id: UUID(), name: name,
                limits: .init(
                    provider: .claude, session: nil,
                    week: index == 2 ? .init(percent: 35, resetsAt: nil) : nil,
                    fable: index == 2 ? .init(percent: 0, resetsAt: nil) : nil,
                    error: index == 2 ? nil : rejected), refreshedAt: Date())
        }
        await store.receiveLimitsSnapshot(
            .init(
                refreshedAt: Date(),
                providers: [
                    .init(
                        provider: .codex, session: nil, week: .init(percent: 21, resetsAt: nil),
                        credits: 0),
                    .init(
                        provider: .cursor, session: nil, week: nil,
                        error: "Sample provider unavailable"),
                    .init(provider: .grok, session: nil, week: .init(percent: 2, resetsAt: nil)),
                ], failure: rejected, claudeAccounts: accounts))
        for width in [310.0, 430.0] {
            for scale in [1.0, 1.5] {
                UIScale.apply(scale)
                for scheme in [ColorScheme.light, .dark] {
                    let host = NSHostingView(
                        rootView: LimitsMenuPanel(store: store)
                            .environment(\.colorScheme, scheme)
                            .padding(14)
                            .frame(width: width, height: 950, alignment: .topLeading)
                            .background(scheme == .dark ? Color.black : Color.white))
                    host.sizingOptions = []
                    host.frame = CGRect(x: 0, y: 0, width: width, height: 950)
                    for _ in 0..<3 {
                        host.layoutSubtreeIfNeeded()
                        try await Task.sleep(for: .milliseconds(20))
                    }
                    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    let image = try #require(bitmap.cgImage)
                    let recognition = VNRecognizeTextRequest()
                    recognition.recognitionLevel = .accurate
                    try VNImageRequestHandler(cgImage: image).perform([recognition])
                    let text =
                        recognition.results?.compactMap { $0.topCandidates(1).first?.string }
                        .joined(separator: " ") ?? ""
                    #expect(text.contains("Sample personal"))
                    #expect(text.contains("Sample current"))
                    #expect(text.contains("Reconnect"))
                    #expect(!text.contains("N/A"))
                    #expect(!text.contains("CLAUDE_CODE_OAUTH_TOKEN"))
                    if width == 310, scale == 1, scheme == .dark,
                        let output = ProcessInfo.processInfo.environment[
                            "EDITH_USAGE_RENDER_OUTPUT"]
                    {
                        let png = try #require(bitmap.representation(using: .png, properties: [:]))
                        try png.write(to: URL(fileURLWithPath: output))
                    }
                }
            }
        }
    }

    @Test func fullDashboardRendersSyntheticUsageAtCompactRegularAndZoomedSizes() async throws {
        let zoom = UIScale.current
        defer { UIScale.apply(zoom) }
        let data = Data(
            #"{"sources":["fixture"],"defaultSources":["fixture"],"sourceMeta":{"fixture":{"label":"Sample source"}},"sessions":[],"daily":[{"period":"2026-10-09","bySource":{"fixture":[{"modelName":"Sample model","inputTokens":120,"outputTokens":30,"cost":2}]},"projects":[],"hours":[]}] }"#
                .utf8)
        let model = DashboardModel()
        model.ingest(try JSONDecoder().decode(DashUsage.self, from: data))
        await model.awaitPendingComputation()
        defer { model.shutdown() }
        for width in [430.0, 1_100.0] {
            for scale in [1.0, 1.5] {
                UIScale.apply(scale)
                for scheme in [ColorScheme.light, .dark] {
                    let host = NSHostingView(
                        rootView: DashboardView(model: model)
                            .environment(\.automaticViewActionsEnabled, false)
                            .environment(\.compactLayout, width < 700)
                            .environment(\.colorScheme, scheme)
                            .transaction { $0.animation = nil }
                            .frame(width: width, height: 900)
                            .background(DashSkin.paper(scheme == .dark)))
                    host.sizingOptions = []
                    host.frame = CGRect(x: 0, y: 0, width: width, height: 900)
                    host.wantsLayer = true
                    #expect(host.window == nil)
                    for _ in 0..<3 {
                        host.layoutSubtreeIfNeeded()
                        try await Task.sleep(for: .milliseconds(20))
                    }
                    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    let image = try #require(bitmap.cgImage)
                    let recognition = VNRecognizeTextRequest()
                    recognition.recognitionLevel = .accurate
                    try VNImageRequestHandler(cgImage: image).perform([recognition])
                    #expect(
                        recognition.results?.contains(where: {
                            $0.topCandidates(1).first?.string.localizedCaseInsensitiveContains(
                                "Agent usage") == true
                        }) == true)
                    #expect(host.window == nil)
                }
            }
        }
    }

    @Test func nativeHomeCardsAndSettingsRenderWithoutAutomaticActions() async throws {
        let previous = UIScale.current
        defer { UIScale.apply(previous) }
        let model = DashboardModel()
        defer { model.shutdown() }
        let today = CalendarDay.stamp(Date())
        let data = try JSONSerialization.data(withJSONObject: [
            "sources": ["sample"], "defaultSources": ["sample"],
            "daily": [
                [
                    "period": today,
                    "bySource": [
                        "sample": [
                            [
                                "modelName": "Sample model", "inputTokens": 25_000_000,
                                "outputTokens": 1_700_000, "cacheReadTokens": 5_000_000, "cost": 0,
                            ]
                        ]
                    ],
                ]
            ],
        ])
        model.ingest(try JSONDecoder().decode(DashUsage.self, from: data))
        await model.awaitPendingComputation()
        let detail = try #require(model.heatDetail[today])
        #expect(detail.tokens == 31_700_000 && detail.cost == 0)
        let usageTile = SurfaceTile(.usage)
        let snapshot = SurfaceUsageSnapshot(
            document: try JSONDecoder().decode(SurfaceUsageDocument.self, from: data),
            tile: usageTile)
        let limitsTile = SurfaceTile(.limits)
        let route = try #require(
            UsageUISceneRoute(context: [
                "location": "home", "section": "limits", "target": "home",
                "tile": try JSONEncoder().encode(limitsTile),
            ]))
        let scene = UsageUIPresentation(id: UUID(), route: route, client: nil)
        defer { scene.shutdown() }
        let limits = UsageCompactLimitsSnapshot.project(
            LimitsTopicSnapshot(
                refreshedAt: Date(),
                providers: [
                    .init(
                        provider: .claude,
                        session: .init(percent: 25, resetsAt: Date().addingTimeInterval(3600)),
                        week: nil)
                ], failure: nil), tile: limitsTile)
        for width in [430.0, 1_100.0] {
            for zoom in [1.0, 1.5] {
                UIScale.apply(zoom)
                for scheme in [ColorScheme.light, .dark] {
                    let views: [(AnyView, String)] = [
                        (
                            AnyView(
                                UsageHomeActivityCard(tile: SurfaceTile(.activity), model: model)),
                            "Activity"
                        ),
                        (AnyView(UsageHomeUsageCard(tile: usageTile, snapshot: snapshot)), "Today"),
                        (
                            AnyView(
                                UsageHomeLimitsCard(
                                    tile: limitsTile, scene: scene, snapshot: limits)),
                            "Rate limits"
                        ),
                        (
                            AnyView(Form { UsageSettingsRows() }.formStyle(.grouped)),
                            "Claude limits"
                        ),
                    ]
                    for (view, label) in views {
                        let host = NSHostingView(
                            rootView:
                                view
                                .environment(\.automaticViewActionsEnabled, false)
                                .environment(\.compactLayout, width < 700)
                                .environment(\.colorScheme, scheme)
                                .transaction { $0.animation = nil }
                                .frame(width: width, height: 900)
                                .background(DashSkin.paper(scheme == .dark)))
                        host.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                        host.sizingOptions = []
                        host.frame = CGRect(x: 0, y: 0, width: width, height: 900)
                        host.wantsLayer = true
                        #expect(host.window == nil)
                        for _ in 0..<3 {
                            host.layoutSubtreeIfNeeded()
                            try await Task.sleep(for: .milliseconds(20))
                        }
                        let bitmap = try #require(
                            host.bitmapImageRepForCachingDisplay(in: host.bounds))
                        host.cacheDisplay(in: host.bounds, to: bitmap)
                        let png = try #require(bitmap.representation(using: .png, properties: [:]))
                        #expect(png.count > 1_000)
                        let image = try #require(bitmap.cgImage)
                        let recognition = VNRecognizeTextRequest()
                        recognition.recognitionLevel = .accurate
                        try VNImageRequestHandler(cgImage: image).perform([recognition])
                        let heading = try #require(
                            recognition.results?.first(where: {
                                $0.topCandidates(1).first?.string.localizedCaseInsensitiveContains(
                                    label) == true
                            }), Comment(rawValue: label))
                        #expect(host.window == nil)
                        #expect(heading.boundingBox.minX > 0 && heading.boundingBox.maxX < 1)
                        #expect((heading.topCandidates(1).first?.confidence ?? 0) > 0.25)
                    }
                }
            }
        }
    }
}
