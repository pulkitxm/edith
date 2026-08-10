import Foundation
import Testing

@testable import EdithCLI
@testable import EdithKit

@Suite struct CLIUsageTests {
    static let document = """
        {
          "generatedAt": "2026-08-07T04:00:00Z",
          "sources": ["cli", "codex"],
          "defaultSources": ["cli"],
          "sourceMeta": { "cli": { "label": "Claude Code", "tool": "Claude Code" } },
          "daily": [
            {
              "period": "2026-08-06",
              "bySource": {
                "cli": [
                  { "modelName": "opus", "inputTokens": 10, "outputTokens": 5,
                    "cacheCreationTokens": 1, "cacheReadTokens": 4, "cost": 2.5 }
                ],
                "codex": [
                  { "modelName": "gpt", "inputTokens": 2, "outputTokens": 2,
                    "cacheCreationTokens": 0, "cacheReadTokens": 0, "cost": 1.0 }
                ]
              },
              "projects": [
                { "projectName": "edith", "path": "/tmp/edith", "cost": 3.5, "tokens": 24 }
              ]
            },
            {
              "period": "2026-08-07",
              "bySource": {
                "cli": [
                  { "modelName": "opus", "inputTokens": 1, "outputTokens": 1,
                    "cacheCreationTokens": 0, "cacheReadTokens": 0, "cost": 0.5 }
                ]
              },
              "projects": [
                { "projectName": "edith", "path": "/tmp/edith", "cost": 0.5, "tokens": 2 }
              ]
            }
          ]
        }
        """

    static func parsed() throws -> UsageDocument {
        try JSONDecoder().decode(UsageDocument.self, from: Data(document.utf8))
    }

    @Test func loadingAMissingFileIsUnavailableRatherThanACrash() {
        do {
            _ = try UsageDocument.load(from: URL(fileURLWithPath: "/nonexistent/usage.json"))
            Issue.record("load should have failed")
        } catch let failure as CLIFailure {
            #expect(failure.kind == .unavailable)
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test func totalsSumEverySourceAndTokenBucket() throws {
        let totals = UsageAnalysis.totals(try Self.parsed().daily, sources: nil)
        #expect(totals.cost == 4.0)
        #expect(totals.tokens == 26)
        #expect(totals.inputTokens == 13)
    }

    @Test func filteringToOneSourceDropsTheOthers() throws {
        let totals = UsageAnalysis.totals(try Self.parsed().daily, sources: ["codex"])
        #expect(totals.cost == 1.0)
        #expect(totals.tokens == 4)
    }

    @Test func perSourceAndPerModelBreakdownsAgree() throws {
        let days = try Self.parsed().daily
        let bySource = UsageAnalysis.bySource(days, sources: nil)
        let byModel = UsageAnalysis.byModel(days, sources: nil)
        #expect(bySource["cli"]?.cost == 3.0)
        #expect(bySource["codex"]?.cost == 1.0)
        #expect(byModel["opus"]?.cost == 3.0)
        #expect(byModel["gpt"]?.cost == 1.0)
    }

    @Test func dailyRowsComeBackInDateOrder() throws {
        let days = UsageAnalysis.byDay(try Self.parsed().daily, sources: nil)
        #expect(days.map(\.0) == ["2026-08-06", "2026-08-07"])
        #expect(days.last?.1.cost == 0.5)
    }

    @Test func projectsAggregateAcrossDaysAndSortByCost() throws {
        let projects = UsageAnalysis.byProject(try Self.parsed().daily)
        #expect(projects.count == 1)
        #expect(projects.first?.0 == "edith")
        #expect(projects.first?.1 == 4.0)
    }

    @Test func rangesSliceOnTheDayStamp() {
        let today = Date(timeIntervalSince1970: 1_786_000_000)
        let stamp = UsageRange.stamp(today)
        #expect(UsageRange.today.includes(period: stamp, today: today))
        #expect(!UsageRange.today.includes(period: "2000-01-01", today: today))
        #expect(UsageRange.all.includes(period: "2000-01-01", today: today))
        #expect(UsageRange.week.includes(period: stamp, today: today))
    }

    @Test func totalsSerialiseWithStableFieldNames() {
        var totals = UsageTotals()
        totals.cost = 1.5
        totals.inputTokens = 2
        guard case let .object(fields) = totals.json else {
            Issue.record("totals should be an object")
            return
        }
        #expect(fields["cost"] == .double(1.5))
        #expect(fields["tokens"] == .double(2))
        #expect(fields["cacheReadTokens"] == .double(0))
    }

    @Test func limitWindowsCarryTheirResetCountdown() {
        let resets = Date().addingTimeInterval(600)
        guard
            case let .object(fields) = LimitsReport.window(
                LimitWindow(percent: 42, resetsAt: resets))
        else {
            Issue.record("window should be an object")
            return
        }
        #expect(fields["percent"] == .double(42))
        guard case let .double(remaining)? = fields["resetsInSeconds"] else {
            Issue.record("countdown should be a number")
            return
        }
        #expect(remaining > 500 && remaining <= 600)
    }

    @Test func missingLimitWindowsAreNullNotZero() {
        #expect(LimitsReport.window(nil) == .null)
    }
}
