import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import SwiftUI
import Testing

@testable import UsageExtension

@Suite(.serialized) @MainActor struct UsageScrollBenchmarkTests {
    static let enabled = ProcessInfo.processInfo.environment["EDITH_SCROLL_BENCHMARK"] != nil

    @Test(.enabled(if: enabled)) func scrollingTheDashboardWithAYearOfSyntheticUsage() async throws
    {
        let only = ProcessInfo.processInfo.environment["EDITH_SCROLL_CASE"]
        let frames = Int(ProcessInfo.processInfo.environment["EDITH_SCROLL_FRAMES"] ?? "") ?? 300
        for scenario in UsageScrollScenario.allCases where only == nil || only == scenario.rawValue
        {
            let timing = try await Self.measure(
                scenario, days: 365, projects: 300, sessions: 5_000, frames: frames)
            print("usage-scroll \(scenario.rawValue): \(timing) slowAt=\(timing.slowOffsets)")
        }
    }

    @Test(arguments: UsageScrollScenario.allCases) func scrollStaysWithinBounds(
        scenario: UsageScrollScenario
    ) async throws {
        let timing = try await Self.measure(
            scenario, days: 120, projects: 120, sessions: 1_000, frames: 120)
        print("usage-scroll regression \(scenario.rawValue): \(timing)")
        #expect(Set(timing.offsets).count > 10)
        #expect(timing.worst < 80)
        #expect(timing.median < 12)
        #expect(timing.hitches < 4)
    }

    static func measure(
        _ scenario: UsageScrollScenario, days: Int, projects: Int, sessions: Int, frames: Int
    ) async throws -> UsageScrollTiming {
        let suite = "usage-scroll-\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let model = DashboardModel(preferences: preferences)
        defer { model.shutdown() }
        model.ingest(
            try JSONDecoder().decode(
                DashUsage.self,
                from: UsageSyntheticYear.document(
                    days: days, projects: projects, sessions: sessions)
            ))
        model.range = .preset(.allTime)
        await model.awaitPendingComputation()
        model.projListOpen = scenario != .page
        let (window, host) = UsageScrollHarness.host(
            DashboardView(model: model)
                .environment(\.automaticViewActionsEnabled, false)
                .environment(\.compactLayout, false)
                .environment(\.colorScheme, .dark),
            size: CGSize(width: 1_100, height: 800))
        await UsageScrollHarness.settle(host, for: .seconds(1))
        if scenario == .projectList { await UsageScrollHarness.revealNestedScroll(in: host) }
        let timing = await UsageScrollHarness.scroll(
            host, inner: scenario == .projectList, frames: frames)
        window.orderOut(nil)
        window.contentView = nil
        return timing
    }
}

enum UsageScrollScenario: String, CaseIterable, CustomTestStringConvertible {
    case page
    case pageWithProjectList
    case projectList

    var testDescription: String { rawValue }
}

enum UsageSyntheticYear {
    typealias Object = [String: Any]

    static let sources = ["cli", "codex", "cursor"]
    static let models = ["sample-large", "sample-medium", "sample-small", "sample-tiny"]

    static func document(days: Int, projects: Int, sessions: Int) throws -> Data {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        var chatNumber = 0
        var daily: [Object] = []
        for offset in 0..<days {
            let date = calendar.date(byAdding: .day, value: -offset, to: today) ?? today
            var day: Object = ["period": DashboardModel.ymd.string(from: date)]
            day["bySource"] = bySource(offset)
            day["projects"] = projectRows(
                offset: offset, date: date, projects: projects,
                chatsPerDay: max(1, sessions / days),
                chatNumber: &chatNumber)
            day["hours"] = hours()
            daily.append(day)
        }
        var sourceMeta: Object = [:]
        for source in sources { sourceMeta[source] = ["label": "Sample \(source)"] }
        var document: Object = ["schemaVersion": 8, "sources": sources]
        document["defaultSources"] = sources
        document["sourceMeta"] = sourceMeta
        document["sessions"] = (0..<sessions).map { index -> Object in
            ["id": "session-\(index)", "source": sources[index % sources.count]]
        }
        document["daily"] = daily
        return try JSONSerialization.data(withJSONObject: document)
    }

    private static func bySource(_ offset: Int) -> Object {
        var result: Object = [:]
        for (index, source) in sources.enumerated() {
            var rows: [Object] = []
            for (position, model) in models.enumerated() {
                var row: Object = ["modelName": model]
                row["inputTokens"] = 40_000 + offset * 13 + position * 900
                row["outputTokens"] = 9_000 + index * 700
                row["cacheCreationTokens"] = 3_000
                row["cacheReadTokens"] = 250_000 + offset * 31
                row["cost"] = Double(1 + (offset + position + index) % 9) / 3
                rows.append(row)
            }
            result[source] = rows
        }
        return result
    }

    private static func projectRows(
        offset: Int, date: Date, projects: Int, chatsPerDay: Int, chatNumber: inout Int
    ) -> [Object] {
        var rows: [Object] = []
        for slot in 0..<max(1, min(projects, 30)) {
            let number = (offset * 7 + slot * 11) % projects
            let tokens = Double(20_000 + (slot * 997 + offset) % 80_000)
            let cost = Double(1 + (slot + offset) % 6)
            var chats: [Object] = []
            if slot < chatsPerDay {
                chatNumber += 1
                let start = date.timeIntervalSince1970 * 1_000 + Double(slot) * 60_000
                var chat: Object = ["id": "session-\(chatNumber)"]
                chat["path"] = "/synthetic/work/project-\(number)"
                chat["title"] = "Sample session \(chatNumber)"
                chat["tokens"] = tokens / 2
                chat["cost"] = cost / 2
                chat["source"] = sources[chatNumber % sources.count]
                chat["firstTs"] = start
                chat["lastTs"] = start + 1_800_000
                chats.append(chat)
            }
            let usage: Object = ["tokens": tokens, "cost": cost]
            let breakdown: Object = [
                "tokens": tokens, "cost": cost, "byModel": ["sample-large": usage],
            ]
            var row: Object = ["projectName": "project-\(number)"]
            row["repositoryID"] = "repo-\(number)"
            row["repositoryName"] = "sample/project-\(number)"
            row["path"] = "/synthetic/work/project-\(number)"
            row["tokens"] = tokens
            row["cost"] = cost
            row["bySource"] = ["cli": breakdown]
            row["chats"] = chats
            rows.append(row)
        }
        return rows
    }

    private static func hours() -> [Object] {
        var rows: [Object] = []
        for hour in 0..<24 {
            let tokens = Double(10_000 + hour * 400)
            let cost = Double(hour % 5) / 2
            let breakdown: Object = ["tokens": tokens, "cost": cost, "byModel": Object()]
            var row: Object = ["tokens": tokens, "cost": cost]
            row["bySource"] = ["cli": breakdown]
            rows.append(row)
        }
        return rows
    }
}
