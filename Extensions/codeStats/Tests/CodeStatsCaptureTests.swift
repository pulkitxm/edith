import AppKit
import EdithExtensionUI
import SwiftUI
import Testing
@testable import CodeStatsExtension

@MainActor @Suite(.serialized) struct CodeStatsCaptureTests {
    static var richCommits: [CodeStatsCommit] {
        let repositories = ["octo/app", "octo/site", "octo/tools", "acme/api", "acme/docs"]
        let languages = ["Swift", "TypeScript", "Python", "Go", "Markdown"]
        var commits: [CodeStatsCommit] = []
        for offset in 0..<88 {
            let date = CodeStatsPageFixture.calendar.date(
                byAdding: .day, value: -offset, to: CodeStatsPageFixture.date("2026-10-05"))!
            let components = CodeStatsPageFixture.calendar.dateComponents(
                [.year, .month, .day], from: date)
            let day = String(
                format: "%04d-%02d-%02d", components.year!, components.month!, components.day!)
            let count = (offset * 7 + 3) % 5
            for index in 0..<count {
                let seed = offset * 13 + index * 5
                commits.append(
                    CodeStatsCommit(
                        sha: "s\(offset)-\(index)", day: day, hour: 8 + seed % 14,
                        repository: repositories[seed % repositories.count],
                        languages: [
                            languages[seed % languages.count]: .init(
                                added: 20 + seed % 180, updated: seed % 40, deleted: seed % 25)
                        ]))
            }
        }
        return commits
    }

    static func populatedModel() async throws -> CodeStatsModel {
        let suite = "test.edith.code-stats.capture.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let commits = richCommits
        let report = CodeStatsReportBuilder.build(
            commits: commits, range: .days(90), today: CodeStatsPageFixture.date("2026-10-05"),
            calendar: CodeStatsPageFixture.calendar)
        let service = CodeStatsFakeAgent(
            status: CodeStatsPageFixture.status(
                reportedAt: CodeStatsPageFixture.date("2026-10-05")),
            reports: [.days(90): report])
        service.facts = CodeStatsFactBuilder.build(commits: commits)
        let model = CodeStatsModel(
            service: service.service, defaults: defaults, calendar: CodeStatsPageFixture.calendar,
            today: { CodeStatsPageFixture.date("2026-10-05") })
        await model.refresh()
        return model
    }

    static func setupModel(running: Bool = false) async throws -> CodeStatsModel {
        let suite = "test.edith.code-stats.capture.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let service = CodeStatsFakeAgent(
            status: CodeStatsPageFixture.status(
                storage: running ? .ready(freeBytes: 500_000_000_000) : .notConfigured,
                active: running
                    ? CodeStatsActiveRun(
                        trigger: .manual, startedAt: Date().addingTimeInterval(-42))
                    : nil))
        let model = CodeStatsModel(
            service: service.service, defaults: defaults, calendar: CodeStatsPageFixture.calendar,
            today: { CodeStatsPageFixture.date("2026-10-05") })
        await model.refresh()
        return model
    }

    static func failingModel() async throws -> CodeStatsModel {
        let suite = "test.edith.code-stats.capture.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        var service = CodeStatsFakeAgent(status: CodeStatsPageFixture.status()).service
        service.status = { throw CodeStatsFailure(.unavailable, "The Code Stats agent stopped.") }
        let model = CodeStatsModel(
            service: service, defaults: defaults, calendar: CodeStatsPageFixture.calendar,
            today: { CodeStatsPageFixture.date("2026-10-05") })
        await model.refresh()
        return model
    }

    @Test func populatedPageRendersEveryVariant() async throws {
        for variant in CodeStatsRenderCapture.variants {
            let model = try await Self.populatedModel()
            #expect(model.phase == .content)
            let bitmap = try await CodeStatsRenderCapture.render(
                "code-stats-populated", variant: variant
            ) { CodeStatsPage(model: model) }
            #expect(CodeStatsRenderCapture.distinctColors(bitmap) > 12)
            model.cancelLoading()
        }
    }

    @Test func fullPopulatedPageRendersEveryCard() async throws {
        let tall = [
            CodeStatsRenderCapture.Variant(
                name: "full-light", width: 1100, height: 3400, zoom: 1, scheme: .light),
            CodeStatsRenderCapture.Variant(
                name: "full-compact-dark", width: 640, height: 4200, zoom: 1, scheme: .dark),
        ]
        for variant in tall {
            let model = try await Self.populatedModel()
            let bitmap = try await CodeStatsRenderCapture.render(
                "code-stats-populated", variant: variant, settle: .milliseconds(600)
            ) { CodeStatsPage(model: model) }
            #expect(CodeStatsRenderCapture.distinctColors(bitmap) > 12)
            model.cancelLoading()
        }
    }

    @Test func setupPageRendersEveryVariant() async throws {
        for variant in CodeStatsRenderCapture.variants {
            let model = try await Self.setupModel()
            #expect(model.phase == .setup)
            try await CodeStatsRenderCapture.render("code-stats-setup", variant: variant) {
                CodeStatsPage(model: model)
            }
            model.cancelLoading()
        }
    }

    @Test func firstSyncLoadingAndErrorStatesRender() async throws {
        let variants = [CodeStatsRenderCapture.variants[0], CodeStatsRenderCapture.variants[3]]
        for variant in variants {
            let running = try await Self.setupModel(running: true)
            #expect(running.phase == .firstRun)
            #expect(running.loadingState == .content)
            try await CodeStatsRenderCapture.render("code-stats-first-sync", variant: variant) {
                CodeStatsPage(model: running)
            }
            running.cancelLoading()

            let idle = CodeStatsModel(
                service: CodeStatsFakeAgent(status: CodeStatsPageFixture.status()).service,
                defaults: try #require(UserDefaults(suiteName: "test.edith.code-stats.idle")))
            #expect(idle.phase == .loading)
            try await CodeStatsRenderCapture.render("code-stats-loading", variant: variant) {
                CodeStatsPage(model: idle)
            }

            let failing = try await Self.failingModel()
            #expect(failing.loadingState == .error)
            try await CodeStatsRenderCapture.render("code-stats-error", variant: variant) {
                CodeStatsPage(model: failing)
            }
        }
    }
}
