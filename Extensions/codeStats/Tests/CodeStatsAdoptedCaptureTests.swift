@testable import CodeStatsExtension
import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import SwiftUI
import Testing

@MainActor @Suite(.serialized) struct CodeStatsAdoptedCaptureTests {
    private static let capturing =
        ProcessInfo.processInfo.environment["EDITH_TEST_CAPTURE_SURFACES"] != nil

    private static var variants: [CodeStatsRenderCapture.Variant] {
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

    private static var fullVariants: [CodeStatsRenderCapture.Variant] {
        [
            .init(name: "full-light", width: 1100, height: 3400, zoom: 1, scheme: .light),
            .init(name: "full-compact-dark", width: 640, height: 4600, zoom: 1, scheme: .dark),
        ]
    }

    private static var commits: [CodeStatsCommit] {
        let repositories = ["octo/app", "octo/site", "octo/tools", "acme/api"]
        let languages = ["Swift", "TypeScript", "Python"]
        var commits: [CodeStatsCommit] = []
        var cursor = DateFilterDay("2026-05-01")!
        let last = DateFilterDay("2026-10-05")!
        var index = 0
        while cursor <= last {
            for slot in 0...(index % 3) {
                commits.append(
                    CodeStatsCommit(
                        sha: "c\(index)-\(slot)", day: cursor.string,
                        hour: 9 + (index + slot * 3) % 11,
                        repository: repositories[(index + slot) % repositories.count],
                        languages: [
                            languages[(index + slot) % languages.count]: .init(
                                added: 40 + index % 90, updated: 8, deleted: 6)
                        ]))
            }
            cursor = cursor.advanced(by: 1)
            index += 1
        }
        return commits
    }

    private func model(_ selection: DateFilterSelection) async throws -> CodeStatsModel {
        let agent = CodeStatsFakeAgent(
            status: CodeStatsPageFixture.status(reportedAt: CodeStatsPageFixture.date("2026-10-01"))
        )
        agent.facts = CodeStatsFactBuilder.build(commits: Self.commits)
        let defaults = try #require(
            UserDefaults(suiteName: "test.edith.code-stats.adopted.\(UUID().uuidString)"))
        let model = CodeStatsModel(
            service: agent.service, defaults: defaults, calendar: CodeStatsPageFixture.calendar,
            today: { CodeStatsPageFixture.date("2026-10-05") })
        await model.refresh()
        await model.select(selection)
        return model
    }

    private func withTheme(_ theme: String, _ body: () async throws -> Void) async throws {
        let defaults = ExtensionScope.process.defaults()
        let prior = defaults.string(forKey: AppStorageKeys.General.theme)
        defaults.set(theme, forKey: AppStorageKeys.General.theme)
        try await Task.sleep(for: .milliseconds(120))
        defer { defaults.set(prior, forKey: AppStorageKeys.General.theme) }
        try await body()
    }

    private static var states: [(String, DateFilterSelection)] {
        [
            ("default", .preset(.last90)),
            ("today", .preset(.today)),
            ("week", .preset(.last7)),
            ("month", .preset(.lastMonth)),
            (
                "custom",
                .custom(
                    DateFilterRange(
                        DateFilterDay("2026-09-03")!, DateFilterDay("2026-09-16")!))
            ),
        ]
    }

    @Test(.enabled(if: capturing)) func adoptedFilterRendersAcrossVariantsAndThemes() async throws {
        for theme in ["accent", "teal"] {
            try await withTheme(theme) {
                for (name, selection) in Self.states {
                    let model = try await model(selection)
                    for variant in Self.variants {
                        let bitmap = try await CodeStatsRenderCapture.render(
                            "code-stats-\(theme)-\(name)", variant: variant,
                            settle: .milliseconds(450)
                        ) { CodeStatsPage(model: model) }
                        #expect(CodeStatsRenderCapture.distinctColors(bitmap) > 12)
                    }
                    model.cancelLoading()
                }
            }
        }
    }

    @Test(.enabled(if: capturing)) func shortRangesRenderEveryCard() async throws {
        for (name, selection) in Self.states where name != "default" {
            let model = try await model(selection)
            for variant in Self.fullVariants {
                let bitmap = try await CodeStatsRenderCapture.render(
                    "code-stats-page-\(name)", variant: variant, settle: .milliseconds(700)
                ) { CodeStatsPage(model: model) }
                #expect(CodeStatsRenderCapture.distinctColors(bitmap) > 12)
            }
            model.cancelLoading()
        }
    }
}
