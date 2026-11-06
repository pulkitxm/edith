import AppKit
import EdithExtensionCore
import EdithExtensionUI
import Foundation
import SwiftUI
import Testing

@testable import AttentionNative

@MainActor
@Suite(.serialized)
struct AttentionRangeLayoutTests {
    private static let apps: [(name: String, bundle: String, title: String)] = [
        ("Fixture Editor", "com.example.fixture.editor", "Sample workspace"),
        ("Fixture Terminal", "com.example.fixture.terminal", "build and test"),
        ("Fixture Notes", "com.example.fixture.notes", "Meeting notes"),
        ("Fixture Chat", "com.example.fixture.chat", "Team room"),
    ]

    private static let ranges: [(name: String, selection: DateFilterSelection)] = [
        ("1d", .preset(.today)), ("7d", .preset(.last7)), ("30d", .preset(.last30)),
        ("90d", .preset(.last90)), ("1y", .preset(.last12Months)), ("all", .preset(.allTime)),
    ]

    private static let variants = [
        AttentionRenderCapture.Variant(
            name: "compact-dark", width: 640, height: 3000, zoom: 1, scheme: .dark),
        AttentionRenderCapture.Variant(
            name: "regular-light", width: 1100, height: 2400, zoom: 1, scheme: .light),
        AttentionRenderCapture.Variant(
            name: "wide-dark", width: 2000, height: 2000, zoom: 1, scheme: .dark),
        AttentionRenderCapture.Variant(
            name: "wide-zoomed-light", width: 2000, height: 2600, zoom: 1.6, scheme: .light),
    ]

    @Test func everyRangeRendersAtEveryWidth() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "attention-range-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = AttentionRepository(root: root)
        try repository.saveSettings(.init(isEnabled: true, trackingEnabled: true))
        let now = Date()
        for day in 0..<200 {
            for slot in 0..<(day == 0 ? 6 : 2 + day % 3) {
                let app = Self.apps[(day + slot) % Self.apps.count]
                try repository.append(
                    AttentionEvent(
                        id: "range-\(day)-\(slot)",
                        startedAt: now.addingTimeInterval(
                            TimeInterval(-day * 86_400 - (slot + 1) * 1_500)),
                        duration: TimeInterval(600 + slot * 120), source: .application,
                        appName: app.name, bundleID: app.bundle, windowTitle: app.title))
            }
        }
        let model = AttentionPageModel(repository: repository)
        model.reload()
        await model.waitForReload()
        #expect(model.loaded && model.hasActivity)
        for range in Self.ranges {
            model.select(range.selection)
            model.reload()
            await model.waitForReload()
            for variant in Self.variants {
                let bitmap = try await AttentionRenderCapture.render(
                    "attention-range-\(range.name)", variant: variant, settle: .milliseconds(500)
                ) { AttentionPage(model: model) }
                #expect(AttentionRenderCapture.distinctColors(bitmap) > 3)
            }
        }
        await model.shutdown()
    }
}
