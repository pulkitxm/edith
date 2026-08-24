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
                { "projectName": "edith", "path": "/tmp/edith", "cost": 3.5, "tokens": 24,
                  "bySource": {
                    "cli": { "tokens": 20, "cost": 2.5 },
                    "codex": { "tokens": 4, "cost": 1.0 }
                  } }
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
                { "projectName": "edith", "path": "/tmp/edith", "cost": 0.5, "tokens": 2,
                  "bySource": { "cli": { "tokens": 2, "cost": 0.5 } } }
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

    @Test func unattributedCostIsNotPresentedAsAModel() throws {
        let document = """
            {
              "daily": [{
                "period": "2026-08-07",
                "bySource": {"codex": [
                  {"modelName": "gpt-5.6-sol", "inputTokens": 100,
                   "outputTokens": 0, "cacheCreationTokens": 0,
                   "cacheReadTokens": 0, "cost": 0},
                  {"modelName": "unattributed-cost", "inputTokens": 0,
                   "outputTokens": 0, "cacheCreationTokens": 0,
                   "cacheReadTokens": 0, "cost": 12},
                  {"modelName": "unknown", "inputTokens": 0,
                   "outputTokens": 0, "cacheCreationTokens": 0,
                   "cacheReadTokens": 0, "cost": 3}
                ]}
              }]
            }
            """
        let parsed = try JSONDecoder().decode(UsageDocument.self, from: Data(document.utf8))
        let models = UsageAnalysis.byModel(parsed.daily, sources: nil)
        let ordered = UsageAnalysis.orderedModels(models)
        #expect(ordered.map(\.0) == ["gpt-5.6-sol", "unattributed-cost"])
        #expect(ordered.last?.1.cost == 15)
        #expect(UsageModelRow.displayName("unattributed-cost") == "Unattributed cost")
        #expect(UsageModelRow.displayName("gpt-5.6-sol") == "gpt-5.6-sol")
    }

    @Test func dailyRowsComeBackInDateOrder() throws {
        let days = UsageAnalysis.byDay(try Self.parsed().daily, sources: nil)
        #expect(days.map(\.0) == ["2026-08-06", "2026-08-07"])
        #expect(days.last?.1.cost == 0.5)
    }

    @Test func projectsAggregateAcrossDaysAndSortByCost() throws {
        let projects = UsageAnalysis.byProject(try Self.parsed().daily)
        #expect(projects.count == 1)
        #expect(projects.first?.repositoryName == "edith")
        #expect(projects.first?.cost == 4.0)
        #expect(projects.first?.tokens == 26.0)
        #expect(projects.first?.folders.count == 1)
    }

    @Test func projectCommandDoesNotSilentlyTruncateAccounting() throws {
        let command = try UsageProjectsListCommand.parse([])
        #expect(command.limit == nil)
        let limited = try UsageProjectsListCommand.parse(["--limit", "25"])
        #expect(limited.limit == 25)
    }

    @Test func projectsNormalizeToCanonicalDailyTotals() throws {
        let document = """
            {
              "sources": ["cli"],
              "daily": [{
                "period": "2026-08-07",
                "bySource": {"cli": [
                  {"modelName": "opus", "inputTokens": 60, "outputTokens": 40,
                   "cacheCreationTokens": 0, "cacheReadTokens": 0, "cost": 10}
                ]},
                "projects": [
                  {"projectName": "one", "tokens": 300, "cost": 30,
                   "chats": [{"source": "cli", "tokens": 300, "cost": 30}]},
                  {"projectName": "two", "tokens": 100, "cost": 10,
                   "worktrees": [{"name": "branch", "tokens": 100, "cost": 10,
                     "chats": [{"source": "cli", "tokens": 100, "cost": 10}]}]}
                ]
              }]
            }
            """
        let parsed = try JSONDecoder().decode(UsageDocument.self, from: Data(document.utf8))
        let projects = UsageAnalysis.byProject(parsed.daily)
        #expect(projects.count == 2)
        #expect(projects[0].repositoryName == "one")
        #expect(projects[0].cost == 7.5)
        #expect(projects[0].tokens == 75)
        #expect(projects[1].repositoryName == "two")
        #expect(projects[1].cost == 2.5)
        #expect(projects[1].tokens == 25)
    }

    @Test func projectHierarchyMergesChatsAcrossDaysAndKeepsWorktrees() throws {
        let document = """
            {
              "sources": ["cli"],
              "daily": [
                {
                  "period": "2026-08-06",
                  "bySource": {"cli": [
                    {"modelName": "opus", "inputTokens": 20, "cost": 2}
                  ]},
                  "projects": [{
                    "repositoryID": "github.com/acme/edith", "repositoryName": "edith",
                    "folderName": "edith", "path": "/tmp/edith",
                    "machineName": "Laptop", "machineID": "laptop",
                    "bySource": {"cli": {"tokens": 20, "cost": 2}},
                    "chats": [{"id": "main-chat", "title": "First title",
                      "path": "/tmp/edith", "source": "cli", "tokens": 5, "cost": 0.5,
                      "lastTs": 10}],
                    "worktrees": [{"name": "feature", "chats": [
                      {"id": "work-chat", "title": "Feature work", "source": "cli",
                       "tokens": 15, "cost": 1.5, "lastTs": 20}
                    ]}]
                  }]
                },
                {
                  "period": "2026-08-07",
                  "bySource": {"cli": [
                    {"modelName": "opus", "inputTokens": 10, "cost": 1}
                  ]},
                  "projects": [{
                    "repositoryID": "github.com/acme/edith", "repositoryName": "edith",
                    "folderName": "edith", "path": "/tmp/edith",
                    "machineName": "Laptop", "machineID": "laptop",
                    "bySource": {"cli": {"tokens": 10, "cost": 1}},
                    "chats": [{"id": "main-chat", "title": "Latest title",
                      "path": "/tmp/edith", "source": "cli", "tokens": 10, "cost": 1,
                      "lastTs": 30}],
                    "worktrees": []
                  }]
                }
              ]
            }
            """
        let parsed = try JSONDecoder().decode(UsageDocument.self, from: Data(document.utf8))
        let project = try #require(UsageAnalysis.byProject(parsed.daily).first)
        let folder = try #require(project.folders.first)
        let direct = try #require(folder.chats.first)
        let worktree = try #require(folder.worktrees.first)

        #expect(project.chatIDs == ["main-chat", "work-chat"])
        #expect(direct.id == "main-chat")
        #expect(direct.title == "Latest title")
        #expect(direct.lastTs == 30)
        #expect(direct.tokens == 15)
        #expect(worktree.name == "feature")
        #expect(worktree.chats.map(\.id) == ["work-chat"])
        #expect(worktree.tokens == 15)
        #expect(folder.tokens == 30)
    }

    @Test func discoverableChatIDsAreTrimmedUniqueAndSorted() throws {
        let document = """
            {"daily": [{"period": "2026-08-07", "projects": [{
              "chats": [{"id": " beta "}, {"id": "alpha"}, {"id": ""}],
              "worktrees": [{"name": "feature", "chats": [
                {"id": "alpha"}, {"id": "work"}
              ]}]
            }]}]}
            """
        let parsed = try JSONDecoder().decode(UsageDocument.self, from: Data(document.utf8))
        #expect(UsageAnalysis.chatIDs(parsed.daily) == ["alpha", "beta", "work"])
    }

    @Test func projectSelectorsIncludeOnlyUnambiguousVisibleNames() throws {
        let document = """
            {"daily": [{"period": "2026-08-07", "bySource": {"cli": [
              {"modelName": "opus", "inputTokens": 30, "cost": 3}
            ]}, "projects": [
              {"repositoryID": "github.com/one/shared", "repositoryName": "shared",
               "bySource": {"cli": {"tokens": 10, "cost": 1}}},
              {"repositoryID": "github.com/two/shared", "repositoryName": "Shared",
               "bySource": {"cli": {"tokens": 10, "cost": 1}}},
              {"repositoryID": "github.com/acme/edith", "repositoryName": "edith",
               "bySource": {"cli": {"tokens": 10, "cost": 1}}}
            ]}]}
            """
        let parsed = try JSONDecoder().decode(UsageDocument.self, from: Data(document.utf8))
        #expect(
            UsageAnalysis.projectSelectors(parsed.daily)
                == [
                    "edith", "github.com/acme/edith", "github.com/one/shared",
                    "github.com/two/shared",
                ])
    }

    @Test func sameRepositoryAcrossMachinesHasDistinctFolders() throws {
        let document = """
            {
              "sources": ["cli"],
              "daily": [{
                "period": "2026-08-07",
                "bySource": {"cli": [
                  {"modelName": "opus", "inputTokens": 70, "outputTokens": 30, "cost": 10}
                ]},
                "projects": [
                  {"repositoryID": "github.com/pulkitxm/edith", "repositoryName": "edith",
                   "repositoryURL": "https://github.com/pulkitxm/edith",
                   "folderName": "edith", "path": "/Users/me/edith",
                   "machineName": "Laptop", "machineID": "laptop-id",
                   "tokens": 300, "cost": 30,
                   "bySource": {"cli": {"tokens": 300, "cost": 30}}},
                  {"repositoryID": "github.com/pulkitxm/edith", "repositoryName": "edith",
                   "repositoryURL": "https://github.com/pulkitxm/edith",
                   "folderName": "edith-work", "path": "/home/me/edith",
                   "machineName": "TUF", "machineID": "tuf-id",
                   "tokens": 100, "cost": 10,
                   "bySource": {"cli": {"tokens": 100, "cost": 10}}}
                ]
              }]
            }
            """
        let parsed = try JSONDecoder().decode(UsageDocument.self, from: Data(document.utf8))
        let projects = UsageAnalysis.byProject(parsed.daily)

        #expect(projects.count == 1)
        #expect(projects[0].repositoryID == "github.com/pulkitxm/edith")
        #expect(projects[0].repositoryName == "edith")
        #expect(projects[0].repositoryURL == "https://github.com/pulkitxm/edith")
        #expect(projects[0].cost == 10)
        #expect(projects[0].tokens == 100)
        #expect(projects[0].folders.count == 2)
        #expect(
            Set(projects[0].folders.compactMap(\.path)) == ["/Users/me/edith", "/home/me/edith"])
        #expect(Set(projects[0].folders.compactMap(\.machineID)) == ["laptop-id", "tuf-id"])
        #expect(projects[0].folders.reduce(0) { $0 + $1.cost } == 10)
        #expect(projects[0].folders.reduce(0) { $0 + $1.tokens } == 100)
    }

    @Test func unsupportedSourceStaysUnattributed() throws {
        let document = """
            {
              "sources": ["cli", "qwen"],
              "daily": [{
                "period": "2026-08-07",
                "bySource": {
                  "cli": [
                    {"modelName": "opus", "inputTokens": 80, "outputTokens": 20, "cost": 10}
                  ],
                  "qwen": [
                    {"modelName": "qwen-max", "inputTokens": 40, "outputTokens": 10, "cost": 5}
                  ]
                },
                "projects": [{
                  "repositoryID": "github.com/pulkitxm/edith", "repositoryName": "edith",
                  "path": "/tmp/edith", "tokens": 400, "cost": 40,
                  "bySource": {
                    "cli": {"tokens": 400, "cost": 40,
                      "byModel": {"transcript-opus-label": {"tokens": 400, "cost": 40}}}
                  }
                }]
              }]
            }
            """
        let parsed = try JSONDecoder().decode(UsageDocument.self, from: Data(document.utf8))
        let projects = UsageAnalysis.byProject(parsed.daily)
        let attributed = projects.first { $0.repositoryID == "github.com/pulkitxm/edith" }
        let unattributed = projects.first { $0.repositoryID == "unattributed" }

        #expect(projects.count == 2)
        #expect(attributed?.cost == 10)
        #expect(attributed?.tokens == 100)
        #expect(unattributed?.repositoryName == "Unattributed")
        #expect(unattributed?.cost == 5)
        #expect(unattributed?.tokens == 50)
        #expect(unattributed?.folders.first?.folderName == "qwen / qwen-max")
        #expect(projects.reduce(0) { $0 + $1.cost } == 15)
        #expect(projects.reduce(0) { $0 + $1.tokens } == 150)
    }

    @Test func repositoriesWithTheSameNameRemainDistinct() throws {
        let document = """
            {
              "sources": ["cli"],
              "daily": [{
                "period": "2026-08-07",
                "bySource": {"cli": [
                  {"modelName": "opus", "inputTokens": 10, "outputTokens": 10, "cost": 2}
                ]},
                "projects": [
                  {"repositoryID": "github.com/one/shared", "repositoryName": "shared",
                   "path": "/tmp/one/shared", "tokens": 10, "cost": 1,
                   "bySource": {"cli": {"tokens": 10, "cost": 1}}},
                  {"repositoryID": "github.com/two/shared", "repositoryName": "shared",
                   "path": "/tmp/two/shared", "tokens": 10, "cost": 1,
                   "bySource": {"cli": {"tokens": 10, "cost": 1}}}
                ]
              }]
            }
            """
        let parsed = try JSONDecoder().decode(UsageDocument.self, from: Data(document.utf8))
        let projects = UsageAnalysis.byProject(parsed.daily)

        #expect(projects.count == 2)
        #expect(
            Set(projects.map(\.repositoryID)) == [
                "github.com/one/shared", "github.com/two/shared",
            ])
        #expect(projects.allSatisfy { $0.repositoryName == "shared" })
    }

    @Test func projectJSONKeepsRepositoryIdentityAndFolders() throws {
        let document = """
            {
              "sources": ["cli"],
              "daily": [{
                "period": "2026-08-07",
                "bySource": {"cli": [
                  {"modelName": "opus", "inputTokens": 8, "outputTokens": 2, "cost": 1}
                ]},
                "projects": [{
                  "repositoryID": "github.com/pulkitxm/edith", "repositoryName": "edith",
                  "repositoryURL": "https://github.com/pulkitxm/edith",
                  "folderName": "edith", "path": "/tmp/edith",
                  "machineName": "Laptop", "machineID": "laptop-id", "tokens": 10, "cost": 1,
                  "bySource": {"cli": {"tokens": 10, "cost": 1}},
                  "chats": [{"id": "main-chat", "title": "Main chat", "source": "cli",
                    "tokens": 4, "cost": 0.4}],
                  "worktrees": [{"name": "feature", "chats": [
                    {"id": "work-chat", "title": "Work chat", "source": "cli",
                     "tokens": 6, "cost": 0.6}
                  ]}]
                }]
              }]
            }
            """
        let parsed = try JSONDecoder().decode(UsageDocument.self, from: Data(document.utf8))
        guard case let .object(fields) = UsageAnalysis.byProject(parsed.daily)[0].json else {
            Issue.record("project should be an object")
            return
        }
        #expect(fields["repositoryID"] == .string("github.com/pulkitxm/edith"))
        #expect(fields["repositoryURL"] == .string("https://github.com/pulkitxm/edith"))
        guard case let .array(folders)? = fields["folders"] else {
            Issue.record("folders should be an array")
            return
        }
        #expect(folders.count == 1)
        guard case let .object(folder)? = folders.first else {
            Issue.record("folder should be an object")
            return
        }
        #expect(folder["path"] == .string("/tmp/edith"))
        #expect(folder["machineID"] == .string("laptop-id"))
        guard case let .array(chats)? = folder["chats"],
            case let .array(worktrees)? = folder["worktrees"],
            case let .object(chat)? = chats.first,
            case let .object(worktree)? = worktrees.first
        else {
            Issue.record("folder hierarchy should be present")
            return
        }
        #expect(chat["id"] == .string("main-chat"))
        #expect(chat["title"] == .string("Main chat"))
        #expect(worktree["name"] == .string("feature"))
    }

    @Test func rangesSliceOnTheDayStampAndCalendarWeek() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let today = calendar.date(from: DateComponents(year: 2026, month: 8, day: 12))!
        let stamp = UsageRange.stamp(today, calendar: calendar)
        #expect(UsageRange.today.includes(period: stamp, today: today, calendar: calendar))
        #expect(
            !UsageRange.today.includes(period: "2000-01-01", today: today, calendar: calendar))
        #expect(UsageRange.all.includes(period: "2000-01-01", today: today, calendar: calendar))
        #expect(
            UsageRange.week.includes(period: "2026-08-10", today: today, calendar: calendar))
        #expect(
            !UsageRange.week.includes(period: "2026-08-09", today: today, calendar: calendar))
    }

    @Test func boundedRangesExcludeFutureDays() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let today = calendar.date(from: DateComponents(year: 2026, month: 8, day: 12))!
        let future = "2026-08-13"
        for range in [UsageRange.today, .week, .month] {
            #expect(!range.includes(period: future, today: today, calendar: calendar))
        }
        #expect(UsageRange.all.includes(period: future, today: today, calendar: calendar))
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
