import AppKit
import EdithExtensionCore
import EdithExtensionUI
import Foundation
import SwiftUI
import Testing

@testable import AttentionNative

@MainActor
@Suite(.serialized) struct AttentionAdoptedCaptureTests {
    private static let capturing =
        ProcessInfo.processInfo.environment["EDITH_TEST_CAPTURE_SURFACES"] != nil

    private static var variants: [AttentionRenderCapture.Variant] {
        [
            .init(name: "regular-light", width: 1100, height: 760, zoom: 1, scheme: .light),
            .init(name: "regular-dark", width: 1100, height: 760, zoom: 1, scheme: .dark),
            .init(name: "compact-light", width: 640, height: 700, zoom: 1, scheme: .light),
            .init(name: "compact-dark", width: 640, height: 700, zoom: 1, scheme: .dark),
            .init(name: "wide-light", width: 1600, height: 900, zoom: 1, scheme: .light),
            .init(name: "wide-dark", width: 1600, height: 900, zoom: 1, scheme: .dark),
            .init(name: "zoom-light", width: 1100, height: 760, zoom: 1.6, scheme: .light),
            .init(name: "zoom-dark", width: 1100, height: 760, zoom: 1.6, scheme: .dark),
        ]
    }

    private func populated() throws -> (AttentionRepository, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "attention-adopted-\(UUID().uuidString)")
        let repository = AttentionRepository(root: root)
        try repository.saveSettings(.init(isEnabled: true, trackingEnabled: true))
        let apps = [
            ("Fixture Editor", "com.example.fixture.editor", "Sample project"),
            ("Fixture Notes", "com.example.fixture.notes", "Weekly plan"),
            ("Fixture Terminal", "com.example.fixture.terminal", "Build output"),
        ]
        let now = Date()
        for index in 0..<400 {
            let app = apps[index % apps.count]
            try repository.append(
                AttentionEvent(
                    id: "adopted-\(index)",
                    startedAt: now.addingTimeInterval(TimeInterval(-(index + 1)) * 7_200),
                    duration: TimeInterval(900 + index % 7 * 120), source: .application,
                    appName: app.0, bundleID: app.1, windowTitle: app.2))
        }
        for offset in stride(from: 310, through: 360, by: 5) {
            try repository.append(
                AttentionEvent(
                    id: "adopted-old-\(offset)",
                    startedAt: now.addingTimeInterval(TimeInterval(-offset) * 86_400),
                    duration: 1_800, source: .application, appName: apps[0].0, bundleID: apps[0].1,
                    windowTitle: apps[0].2))
        }
        return (repository, root)
    }

    private static var emptyRange: DateFilterSelection {
        let calendar = Calendar.current
        let now = Date()
        return .custom(
            DateFilterRange(
                DateFilterDay(date: now.addingTimeInterval(-110 * 86_400), calendar: calendar),
                DateFilterDay(date: now.addingTimeInterval(-100 * 86_400), calendar: calendar)))
    }

    private func withTheme(_ theme: String, _ body: () async throws -> Void) async throws {
        let defaults = ExtensionScope.process.defaults()
        let prior = defaults.string(forKey: AppStorageKeys.General.theme)
        defaults.set(theme, forKey: AppStorageKeys.General.theme)
        try await Task.sleep(for: .milliseconds(120))
        defer { defaults.set(prior, forKey: AppStorageKeys.General.theme) }
        try await body()
    }

    @Test(.enabled(if: capturing)) func adoptedFilterRendersAcrossVariantsAndThemes() async throws {
        let (repository, root) = try populated()
        defer { try? FileManager.default.removeItem(at: root) }
        for theme in ["accent", "teal"] {
            try await withTheme(theme) {
                for (name, selection) in [
                    ("default", DateFilterSelection.preset(.today)),
                    ("week", .preset(.thisWeek)), ("retention", .preset(.lastYear)),
                    ("empty", Self.emptyRange),
                ] {
                    let model = AttentionPageModel(repository: repository)
                    model.select(selection)
                    model.reload()
                    await model.waitForReload()
                    for variant in Self.variants {
                        let bitmap = try await AttentionRenderCapture.render(
                            "attention-\(theme)-\(name)", variant: variant,
                            settle: .milliseconds(450)
                        ) { AttentionPage(model: model) }
                        #expect(AttentionRenderCapture.distinctColors(bitmap) > 3)
                    }
                    await model.shutdown()
                }
            }
        }
    }
}
