import AppKit
import EdithExtensionCore
import EdithExtensionUI
import SwiftUI
import Testing
@testable import CodeStatsExtension

@MainActor @Suite(.serialized) struct CodeStatsRangeLayoutTests {
    static let ranges: [(name: String, selection: DateFilterSelection)] = [
        ("1d", .preset(.today)), ("7d", .preset(.last7)), ("30d", .preset(.last30)),
        ("90d", .preset(.last90)), ("1y", .preset(.last12Months)), ("all", .preset(.allTime)),
    ]

    static let captureVariants = [
        CodeStatsRenderCapture.Variant(
            name: "compact-dark", width: 640, height: 3600, zoom: 1, scheme: .dark),
        CodeStatsRenderCapture.Variant(
            name: "regular-light", width: 1100, height: 2600, zoom: 1, scheme: .light),
        CodeStatsRenderCapture.Variant(
            name: "wide-dark", width: 2000, height: 2200, zoom: 1, scheme: .dark),
        CodeStatsRenderCapture.Variant(
            name: "zoomed-dark", width: 1100, height: 3600, zoom: 1.6, scheme: .dark),
        CodeStatsRenderCapture.Variant(
            name: "wide-zoomed-light", width: 2000, height: 2600, zoom: 1.6, scheme: .light),
    ]

    nonisolated static let today = CodeStatsPageFixture.date("2026-10-05")

    static var longCommits: [CodeStatsCommit] {
        let repositories = ["octo/app", "octo/site", "octo/tools", "acme/api", "acme/docs"]
        let languages = ["Swift", "TypeScript", "Python", "Go", "Markdown"]
        var commits: [CodeStatsCommit] = []
        for offset in 0..<900 {
            let date = CodeStatsPageFixture.calendar.date(
                byAdding: .day, value: -offset, to: today)!
            let components = CodeStatsPageFixture.calendar.dateComponents(
                [.year, .month, .day], from: date)
            let day = String(
                format: "%04d-%02d-%02d", components.year!, components.month!, components.day!)
            let count = offset == 0 ? 3 : (offset * 7 + 3) % 6
            for index in 0..<count {
                let seed = offset * 13 + index * 5
                commits.append(
                    CodeStatsCommit(
                        sha: "r\(offset)-\(index)", day: day, hour: 8 + seed % 14,
                        repository: repositories[seed % repositories.count],
                        languages: [
                            languages[seed % languages.count]: .init(
                                added: 20 + seed % 180, updated: seed % 40, deleted: seed % 25)
                        ]))
            }
        }
        return commits
    }

    static func model() async throws -> CodeStatsModel {
        let suite = "test.edith.code-stats.range.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let commits = longCommits
        let report = CodeStatsReportBuilder.build(
            commits: commits, range: .days(90), today: today,
            calendar: CodeStatsPageFixture.calendar)
        let service = CodeStatsFakeAgent(
            status: CodeStatsPageFixture.status(reportedAt: today), reports: [.days(90): report])
        service.facts = CodeStatsFactBuilder.build(commits: commits)
        let model = CodeStatsModel(
            service: service.service, defaults: defaults, calendar: CodeStatsPageFixture.calendar,
            today: { today })
        await model.refresh()
        return model
    }

    @Test func everyRangeRendersAtEveryWidth() async throws {
        for variant in Self.captureVariants {
            let model = try await Self.model()
            #expect(model.table != nil)
            for range in Self.ranges {
                await model.select(range.selection)
                #expect(model.report != nil)
                let bitmap = try await CodeStatsRenderCapture.render(
                    "code-stats-range-\(range.name)", variant: variant, settle: .milliseconds(500)
                ) { CodeStatsPage(model: model) }
                #expect(CodeStatsRenderCapture.distinctColors(bitmap) > 12)
            }
            model.cancelLoading()
        }
    }

    struct Probe {
        var sections: [String: CGRect] = [:]
        var cells: [CGRect] = []
        var calendar: CGRect?
        var topDaysText: [CGRect] = []
    }

    static func probe(_ host: NSView) -> Probe {
        var probe = Probe()
        func visit(_ node: NSObject, depth: Int, inTopDays: Bool) {
            guard depth < 64 else { return }
            let object = node as AnyObject
            let identifier = object.accessibilityIdentifier?() ?? ""
            let label = object.accessibilityLabel?() ?? ""
            let frame = object.accessibilityFrame?() ?? .zero
            if identifier.hasPrefix("code-stats-") { probe.sections[identifier] = frame }
            if label == "Activity calendar" {
                probe.calendar = frame
            } else if label.hasPrefix("Activity ") {
                probe.cells.append(frame)
            }
            let topDays = inTopDays || identifier == "code-stats-top-days"
            if topDays, object.accessibilityRole?() == .staticText, frame.width > 0 {
                probe.topDaysText.append(frame)
            }
            for child in object.accessibilityChildren?() as? [NSObject] ?? [] {
                visit(child, depth: depth + 1, inTopDays: topDays)
            }
        }
        visit(host, depth: 0, inTopDays: false)
        return probe
    }

    static func withAccessibility<T>(_ body: () async throws -> T) async rethrows -> T {
        _ = CodeStatsRenderCapture.application
        let attributes = ["AXManualAccessibility", "AXEnhancedUserInterface"].map {
            NSAccessibility.Attribute(rawValue: $0)
        }
        let prior = attributes.map { NSApp.accessibilityAttributeValue($0) }
        for attribute in attributes { NSApp.accessibilitySetValue(true, forAttribute: attribute) }
        defer {
            for (attribute, value) in zip(attributes, prior) {
                NSApp.accessibilitySetValue(value ?? false, forAttribute: attribute)
            }
        }
        return try await body()
    }

    static let geometryVariants = [
        CodeStatsRenderCapture.Variant(
            name: "geometry-compact", width: 640, height: 3600, zoom: 1, scheme: .dark),
        CodeStatsRenderCapture.Variant(
            name: "geometry-regular", width: 1100, height: 2600, zoom: 1, scheme: .light),
        CodeStatsRenderCapture.Variant(
            name: "geometry-wide", width: 2000, height: 2200, zoom: 1, scheme: .dark),
        CodeStatsRenderCapture.Variant(
            name: "geometry-wide-zoomed", width: 2000, height: 2600, zoom: 1.6, scheme: .light),
    ]

    @Test func contributionsKeepSquareCellsAndFillTheirCardAtEveryRange() async throws {
        try await Self.withAccessibility { try await checkGeometry() }
    }

    private func checkGeometry() async throws {
        for variant in Self.geometryVariants {
            let model = try await Self.model()
            var rowTop: CGFloat?
            for range in Self.ranges {
                await model.select(range.selection)
                var probe = Probe()
                try await CodeStatsRenderCapture.render(
                    "code-stats-geometry-\(range.name)", variant: variant,
                    settle: .milliseconds(500),
                    inspect: { probe = Self.probe($0) }
                ) { CodeStatsPage(model: model) }
                let label = "\(variant.name) \(range.name)"
                let contributions = try #require(
                    probe.sections["code-stats-contributions"], "\(label) lost Contributions")
                let calendar = try #require(probe.calendar, "\(label) lost the calendar")
                let trend = try #require(probe.sections["code-stats-trend"], "\(label) lost trend")
                #expect(probe.sections["code-stats-top-days"] != nil, "\(label) lost Top days")
                #expect(!probe.cells.isEmpty, "\(label) drew no heatmap cells")
                for cell in probe.cells {
                    #expect(abs(cell.width - cell.height) <= 1, "\(label) cell \(cell.size)")
                    #expect(cell.width <= 28 * variant.zoom + 1, "\(label) cell \(cell.size)")
                    #expect(cell.width >= 14 * variant.zoom - 1, "\(label) cell \(cell.size)")
                }
                let compact = variant.width < 720 * variant.zoom
                if !compact {
                    #expect(
                        abs(trend.maxY - contributions.maxY) <= 1,
                        "\(label) moved the trend out of the Contributions row")
                    if let rowTop {
                        #expect(
                            abs(rowTop - contributions.maxY) <= 1,
                            "\(label) moved the Contributions row")
                    } else {
                        rowTop = contributions.maxY
                    }
                }
                if variant.width >= 2000 {
                    let padding = PageMetrics.cardPadding * variant.zoom
                    let unused = contributions.maxX - padding - calendar.maxX
                    #expect(
                        unused <= contributions.width * 0.12,
                        "\(label) left \(unused) of \(contributions.width) unused")
                }
                let rows = Dictionary(grouping: probe.topDaysText) { ($0.midY / 4).rounded() }
                    .values.filter { $0.count >= 3 }
                #expect(range.name == "1d" || !rows.isEmpty, "\(label) found no Top days rows")
                for row in rows {
                    let span = row.map(\.maxX).max()! - row.map(\.minX).min()!
                    #expect(
                        span <= CodeStatsTopDaysCard.listMaximumWidth * variant.zoom + 1,
                        "\(label) spread a Top days row across \(span)")
                }
            }
            model.cancelLoading()
        }
    }
}
