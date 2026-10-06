import AppKit
import EdithKit
import SwiftUI
import Testing

@testable import Edith

@MainActor
@Suite(.serialized) struct AnalyticsLoadingRenderingTests {
    @Test func sharedSkeletonIsVisibleOnTheFirstFrame() throws {
        let host = try auditHost(
            LoadingContainer(state: .loading) {
                Color.blue
            } placeholder: {
                Color(.sRGB, red: 1, green: 0, blue: 0, opacity: 1).frame(width: 160, height: 80)
            }
            .environment(\.loadingAnimationsEnabled, false),
            size: CGSize(width: 160, height: 80))
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let center = try #require(
            bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.usingColorSpace(
                .deviceRGB))
        #expect(center.redComponent > 0.9)
        #expect(center.blueComponent < 0.1)
    }

    @Test func codeChartsKeepSkeletonsBetweenStatusAndReportLoading() async throws {
        let fixture = try models()
        defer { fixture.cleanup() }
        await fixture.code.loadStatus()
        #expect(fixture.code.loadingState == .loading)
        let host = try auditHost(
            CodeStatsPage(model: fixture.code)
                .environment(\.automaticViewActionsEnabled, false)
                .environment(\.loadingAnimationsEnabled, false)
                .environment(\.colorScheme, .dark),
            size: CGSize(width: 1200, height: 850))
        #expect(!(try auditText(host)).contains("Choose folder"))
        try capture(host, name: "code-stats-pending-report")
    }

    @Test func allAnalyticsPagesExposeRecoveryAtCompactZoom() throws {
        let previous = UIScale.current
        UIScale.apply(1.6)
        defer { UIScale.apply(previous) }
        for scheme in [ColorScheme.light, .dark] {
            let fixture = try models()
            defer { fixture.cleanup() }
            let message = "Sample service is temporarily unavailable."
            fixture.attention.loading.fail(fixture.attention.loading.begin(), message: message)
            fixture.usage.contentLoad.fail(fixture.usage.contentLoad.begin(), message: message)
            fixture.code.statusLoad.fail(fixture.code.statusLoad.begin(), message: message)
            for (name, view) in pages(fixture) {
                let host = try auditHost(
                    view.environment(\.compactLayout, true).environment(\.colorScheme, scheme),
                    size: CGSize(width: 680, height: 760))
                host.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                host.layoutSubtreeIfNeeded()
                let text = try auditText(host)
                #expect(text.contains("Retry"), "\(name): \(text)")
                #expect(text.contains("temporarily unavailable"), "\(name): \(text)")
                try capture(host, name: "\(name)-recovery-\(scheme)")
            }
        }
    }

    @Test func analyticsLoadingRendersAtRegularAndCompactWidths() async throws {
        let previous = UIScale.current
        defer { UIScale.apply(previous) }
        for (width, zoom) in [(1200.0, 1.0), (680.0, 1.6)] {
            UIScale.apply(zoom)
            for scheme in [ColorScheme.light, .dark] {
                let fixture = try models()
                defer { fixture.cleanup() }
                for (name, view) in pages(fixture) {
                    let host = try auditHost(
                        view.environment(\.compactLayout, width < 900)
                            .environment(\.colorScheme, scheme)
                            .environment(\.loadingAnimationsEnabled, false),
                        size: CGSize(width: width, height: 850))
                    host.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                    try await Task.sleep(for: .milliseconds(200))
                    host.layoutSubtreeIfNeeded()
                    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    #expect(bitmap.pixelsWide >= Int(width))
                    #expect(bitmap.pixelsHigh >= 850)
                    try capture(host, name: "\(name)-loading-\(Int(width))-\(scheme)")
                }
            }
        }
    }

    @Test func loadingMotionEvidenceUsesTheActualAnalyticsScreens() async throws {
        guard ProcessInfo.processInfo.environment["EDITH_TEST_EVIDENCE_DIR"] != nil else { return }
        let fixture = try models()
        defer { fixture.cleanup() }
        let views = pages(fixture)
        let host = try auditHost(
            HStack(alignment: .top, spacing: 1) {
                ForEach(views.indices, id: \.self) { index in
                    views[index].1.frame(width: 800)
                }
            }
            .environment(\.colorScheme, .dark)
            .environment(\.scenePhase, .active)
            .environment(\.windowVisible, true)
            .environment(\.compactLayout, false),
            size: CGSize(width: 2402, height: 850))
        let window = TestWindowHost.window(contentRect: host.frame)
        window.contentView = host
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        for frame in 0..<24 {
            try await Task.sleep(for: .milliseconds(100))
            host.layoutSubtreeIfNeeded()
            try capture(host, name: String(format: "analytics-motion-%03d", frame))
        }
    }

    private struct Models {
        let attention: AttentionPageModel
        let usage: DashboardModel
        let code: CodeStatsModel
        let cleanup: () -> Void
    }

    private func models() throws -> Models {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("analytics-rendering-\(UUID().uuidString)")
        let suite = "com.pulkit.edith.tests.analytics.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let attention = AttentionPageModel(repository: AttentionRepository(root: root))
        let usage = DashboardModel(preferences: defaults)
        let agent = CodeStatsFakeAgent(status: CodeStatsPageFixture.status())
        let code = CodeStatsModel(service: agent.service, defaults: defaults)
        return Models(attention: attention, usage: usage, code: code) {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func pages(_ models: Models) -> [(String, AnyView)] {
        [
            ("attention", AnyView(AttentionPage(model: models.attention))),
            ("usage", AnyView(DashboardView(model: models.usage))),
            ("code-stats", AnyView(CodeStatsPage(model: models.code))),
        ]
    }

    private func capture(_ host: NSView, name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["EDITH_TEST_EVIDENCE_DIR"] else {
            return
        }
        let root = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: root.appendingPathComponent(name + ".png"))
        #expect(TestWindowHost.exposedWindows.isEmpty)
    }
}
