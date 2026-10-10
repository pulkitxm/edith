import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import SwiftUI
import Testing
import Vision
@testable import UsageExtension

@MainActor @Suite(.serialized) struct UsageDashboardRenderingTests {
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
                            .background(UsageExtension.DashSkin.paper(scheme == .dark)))
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
                                .background(UsageExtension.DashSkin.paper(scheme == .dark)))
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
