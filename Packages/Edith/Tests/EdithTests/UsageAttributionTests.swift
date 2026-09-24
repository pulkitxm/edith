import EdithKit
import Foundation
import Testing

@testable import EdithKit

enum AttributionFixture {
    static let machine = "0f0e0d0c-0b0a-4090-8070-605040302010"
    static let codex = "machine:\(machine):codex"
    static let edith = UsageAttributionRepository(
        id: "github.com/acme/edith", name: "edith", url: "https://github.com/acme/edith")
    static let quinjet = UsageAttributionRepository(
        id: "github.com/acme/quinjet", name: "quinjet", url: "https://github.com/acme/quinjet")

    static func chat(
        _ id: String, _ title: String, source: String = "cli", cost: Double, tokens: Double
    ) -> [String: Any] {
        ["id": id, "title": title, "source": source, "cost": cost, "tokens": tokens]
    }

    static func project(
        _ id: String, _ name: String, path: String, source: String = "cli", cost: Double,
        tokens: Double, chats: [[String: Any]] = [], remote: Bool = false
    ) -> [String: Any] {
        var project: [String: Any] = [
            "projectName": name, "repositoryID": id, "repositoryName": name,
            "repositoryURL": id.hasPrefix("github.com/") ? "https://\(id)" : NSNull(),
            "folderName": name, "path": path, "cost": cost, "tokens": tokens, "chats": chats,
            "worktrees": [[String: Any]](),
            "bySource": [
                source: [
                    "cost": cost, "tokens": tokens,
                    "byModel": ["m": ["cost": cost, "tokens": tokens]],
                ]
            ],
        ]
        if remote {
            project["machineID"] = machine
            project["machineName"] = "tuf"
        }
        return project
    }

    static let projects: [[String: Any]] = [
        project(
            "github.com/acme/edith", "edith", path: "/Users/me/code/edith", cost: 4, tokens: 400),
        project(
            "github.com/acme/quinjet", "quinjet", path: "/Users/me/code/quinjet", cost: 2,
            tokens: 200),
        project(
            "folder:/Users/me/code/edith-worktrees/feature-x", "feature-x",
            path: "/Users/me/code/edith-worktrees/feature-x", cost: 3, tokens: 300,
            chats: [chat("fx1", "Chat 1a2b3c4d", cost: 3, tokens: 300)]),
        project(
            "folder:/tmp/scratch", "scratch", path: "/tmp/scratch", cost: 1.5, tokens: 150,
            chats: [chat("s1", "Draft the launch post", cost: 1.5, tokens: 150)]),
        project(
            "machine:\(machine):folder:", "unknown", path: "machine:\(machine):", source: codex,
            cost: 4, tokens: 400,
            chats: [
                chat("c1", "Fix quinjet deploy", source: codex, cost: 1, tokens: 101),
                chat("c2", "Chat 9f8e7d6c", source: codex, cost: 1, tokens: 99),
                chat("c3", "Update edith and quinjet readme", source: codex, cost: 2, tokens: 200),
            ], remote: true),
    ]

    static func sums(_ projects: [[String: Any]]) -> [String: [Double]] {
        var sums: [String: [Double]] = [:]
        for project in projects {
            for (source, value) in project["bySource"] as? [String: Any] ?? [:] {
                let breakdown = value as? [String: Any] ?? [:]
                let current = sums[source] ?? [0, 0]
                sums[source] = [
                    current[0] + UsageAttribution.number(breakdown["cost"]),
                    current[1] + UsageAttribution.number(breakdown["tokens"]),
                ]
            }
        }
        return sums
    }

    static func document(
        _ projects: [[String: Any]] = projects, retained: Bool = false
    ) -> Data {
        let sums = sums(projects)
        let sources = sums.keys.sorted()
        let cost = sums.values.reduce(0) { $0 + $1[0] }
        let tokens = sums.values.reduce(0) { $0 + $1[1] }
        var document: [String: Any] = [
            "schemaVersion": 8, "generatedAt": "2026-09-20T00:00:00Z", "sources": sources,
            "defaultSources": sources, "sessions": [[String: Any]](),
            "sourceMeta": Dictionary(uniqueKeysWithValues: sources.map { ($0, ["label": $0]) }),
            "totals": [
                "cost": cost, "tokens": tokens, "inputTokens": tokens, "outputTokens": 0,
                "cacheCreationTokens": 0, "cacheReadTokens": 0,
                "bySource": sums.mapValues { ["cost": $0[0], "tokens": $0[1]] },
            ],
            "daily": [
                [
                    "period": "2026-09-20", "projects": projects,
                    "bySource": sums.mapValues {
                        [
                            [
                                "modelName": "m", "inputTokens": $0[1], "outputTokens": 0,
                                "cacheCreationTokens": 0, "cacheReadTokens": 0, "cost": $0[0],
                            ]
                        ]
                    },
                    "hours": (0..<24).map {
                        ["hour": $0, "cost": 0, "tokens": 0, "bySource": [:], "byPath": [:]]
                    },
                ]
            ],
        ]
        if retained {
            document["historyRetention"] = ["version": 1, "blocks": [["period": "2026-09-20"]]]
        }
        return try! JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
    }

    static func projects(in data: Data) -> [[String: Any]] {
        let document = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let days = document?["daily"] as? [[String: Any]] ?? []
        return days.first?["projects"] as? [[String: Any]] ?? []
    }

    static func project(_ id: String, in data: Data) -> [[String: Any]] {
        projects(in: data).filter { $0["repositoryID"] as? String == id }
    }

    static func decision(
        _ repository: UsageAttributionRepository?, _ method: UsageAttributionDecision.Method = .jev
    ) -> UsageAttributionDecision {
        UsageAttributionDecision(
            method: method, repository: repository, confidence: 0.9, folder: "scratch",
            decidedAt: Date(timeIntervalSince1970: 0))
    }
}

@Suite struct UsageAttributionTests {
    typealias Fixture = AttributionFixture

    @Test func namesMoveFoldersAndChatsAndLeaveAmbiguityAlone() throws {
        let original = Fixture.document()
        #expect(UsageHistory.isValidDocument(original))
        let result = UsageAttribution.attributed(original, cache: UsageAttributionCache())
        #expect(result != original)
        #expect(UsageHistory.isValidDocument(result))
        let edith = Fixture.project(Fixture.edith.id, in: result)
        #expect(edith.count == 2)
        let moved = try #require(edith.first { $0["attribution"] != nil })
        #expect(moved["path"] as? String == "/Users/me/code/edith-worktrees/feature-x")
        #expect(moved["folderName"] as? String == "feature-x")
        #expect((moved["attribution"] as? [String: Any])?["method"] as? String == "name")
        let quinjet = try #require(
            Fixture.project(Fixture.quinjet.id, in: result).first { $0["attribution"] != nil })
        #expect((quinjet["chats"] as? [[String: Any]])?.map { $0["id"] as? String } == ["c1"])
        #expect(quinjet["cost"] as? Double == 1)
        #expect(quinjet["tokens"] as? Double == 100)
        let unknown = try #require(
            Fixture.project("machine:\(Fixture.machine):folder:", in: result).first)
        #expect(
            (unknown["chats"] as? [[String: Any]])?.compactMap { $0["id"] as? String }
                == ["c2", "c3"])
        #expect(Fixture.project("folder:/tmp/scratch", in: result).count == 1)
    }

    @Test func totalsAreUnchangedAndApplyingTwiceChangesNothing() {
        let cache = UsageAttributionCache(decisions: [
            "folder||folder:/tmp/scratch": Fixture.decision(Fixture.quinjet)
        ])
        let original = Fixture.document()
        let once = UsageAttribution.attributed(original, cache: cache)
        #expect(UsageAttribution.attributed(once, cache: cache) == once)
        let before = Fixture.sums(Fixture.projects(in: original))
        let after = Fixture.sums(Fixture.projects(in: once))
        #expect(Set(before.keys) == Set(after.keys))
        for (source, value) in before {
            #expect(abs(value[0] - (after[source]?[0] ?? 0)) < 1e-9)
            #expect(value[1] == after[source]?[1])
        }
        for project in Fixture.projects(in: once) {
            let sources = (project["bySource"] as? [String: Any] ?? [:]).values
                .compactMap { $0 as? [String: Any] }
            let cost = sources.reduce(0) { $0 + UsageAttribution.number($1["cost"]) }
            #expect(abs(UsageAttribution.number(project["cost"]) - cost) < 1e-9)
        }
    }

    @Test func forgettingDecisionsPutsFoldersBack() throws {
        let jev = UsageAttributionCache(decisions: [
            "folder||folder:/tmp/scratch": Fixture.decision(Fixture.quinjet)
        ])
        let original = Fixture.document()
        let moved = UsageAttribution.attributed(original, cache: jev)
        let scratch = try #require(
            Fixture.project(Fixture.quinjet.id, in: moved).first {
                $0["path"] as? String == "/tmp/scratch"
            })
        #expect((scratch["attribution"] as? [String: Any])?["method"] as? String == "jev")
        let reset = UsageAttribution.attributed(moved, cache: UsageAttributionCache())
        #expect(
            reset == UsageAttribution.attributed(original, cache: UsageAttributionCache()))
        let none = UsageAttributionCache(decisions: [
            "folder||folder:/Users/me/code/edith-worktrees/feature-x": Fixture.decision(nil)
        ])
        let kept = UsageAttribution.attributed(original, cache: none)
        #expect(
            Fixture.project("folder:/Users/me/code/edith-worktrees/feature-x", in: kept).count == 1)
    }

    @Test func aFolderSeenAgainJoinsItsMovedRecord() {
        let empty = UsageAttributionCache()
        let path = "/Users/me/code/edith-worktrees/feature-x"
        let moved = Fixture.projects(
            in: UsageAttribution.attributed(Fixture.document(), cache: empty))
        let again = Fixture.project(
            "folder:\(path)", "feature-x", path: path, source: "codex", cost: 1, tokens: 10)
        let result = UsageAttribution.attributed(Fixture.document(moved + [again]), cache: empty)
        let feature = Fixture.project(Fixture.edith.id, in: result).filter {
            $0["path"] as? String == path
        }
        #expect(feature.count == 1)
        #expect(
            Set((feature.first?["bySource"] as? [String: Any] ?? [:]).keys) == ["cli", "codex"])
        #expect(Fixture.project("folder:\(path)", in: result).isEmpty)
    }

    @Test func retainedDaysAreLeftUntouched() {
        let retained = Fixture.document(retained: true)
        #expect(UsageAttribution.apply(retained, cache: UsageAttributionCache()) == retained)
    }

    @Test func theMatcherNeedsExactlyOneClearName() {
        let matcher = UsageAttributionMatcher(repositories: [
            Fixture.edith, Fixture.quinjet,
            UsageAttributionRepository(id: "github.com/acme/api", name: "api"),
        ])
        #expect(matcher.folder(name: "Edith-main", path: "/tmp/Edith-main") == Fixture.edith)
        #expect(matcher.folder(name: "x", path: "/Users/quinjet/work/edith-fix") == Fixture.edith)
        #expect(matcher.folder(name: "x", path: "/srv/edith/quinjet") == nil)
        #expect(matcher.folder(name: "api", path: "/srv/api") == nil)
        #expect(matcher.title("Ship acme/quinjet release") == Fixture.quinjet)
        #expect(matcher.title("Update edith and quinjet") == nil)
        #expect(matcher.title("Chat 1a2b3c4d") == nil)
        #expect(matcher.title("Write the api docs") == nil)
    }
}
