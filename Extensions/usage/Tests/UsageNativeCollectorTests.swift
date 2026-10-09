import Foundation
import Testing
@testable import UsageExtension

@Suite(.serialized) struct UsageNativeCollectorTests {
    @Test func completeOfflineCollectionPreservesHoursProjectsChatsAndRestart() async throws {
        try await fixture { home, data in
            let repo = home.appendingPathComponent("projects/mock-project")
            try write(
                Data(
                    "[remote \"origin\"]\n url = https://mock:secret@github.com/example/mock-project.git\n"
                        .utf8), repo.appendingPathComponent(".git/config"))
            try write(
                claude(id: "one", cwd: repo.path),
                home.appendingPathComponent(".claude/projects/mock/session.jsonl"))
            let codex: [[String: Any]] = [
                ["type": "session_meta", "payload": ["id": "native-session", "cwd": repo.path]],
                ["type": "turn_context", "payload": ["model": "gpt-5"]],
                [
                    "type": "token_usage_record", "timestamp": "2026-09-05T03:00:00Z",
                    "payload": [
                        "response_id": "request-two", "thread_id": "native-session",
                        "usage": [
                            "input_tokens": 50, "cached_input_tokens": 10, "output_tokens": 5,
                        ], "costUSD": 2,
                    ],
                ],
            ]
            try write(
                try lines(codex), home.appendingPathComponent(".codex/sessions/session.jsonl"))
            let cursor: [String: Any] = [
                "id": "cursor-one", "timestamp": "2026-09-05T04:00:00Z", "model": "gpt-5",
                "conversationId": "mock-chat", "cwd": repo.path,
                "tokenUsage": ["inputTokens": 5, "outputTokens": 2], "chargedCents": 25,
            ]
            try write(
                try lines([cursor]), home.appendingPathComponent(".cursor/chats/mock/usage.jsonl"))
            let openCode = openCodeRow(id: "opencode-one", cwd: repo.path)
            try write(
                try UsageNativeJSON.encode(openCode),
                home.appendingPathComponent(".local/share/opencode/storage/message/mock/one.json"))
            let first = try await collect(home, data)
            try validate(first)
            #expect(
                Set(first["sources"] as? [String] ?? []) == ["cli", "codex", "cursor", "opencode"])
            let totals = try #require(first["totals"] as? [String: Any])
            #expect(totals["tokens"] as? Double == 82)
            #expect(abs((totals["cost"] as? Double ?? 0) - 4.25) < 0.000001)
            let day = try #require((first["daily"] as? [[String: Any]])?.first)
            let projects = try #require(day["projects"] as? [[String: Any]])
            #expect(projects.count == 1)
            #expect(projects[0]["repositoryID"] as? String == "github.com/example/mock-project")
            #expect((projects[0]["chats"] as? [[String: Any]])?.count == 4)
            #expect(
                !FileManager.default.fileExists(
                    atPath: data.appendingPathComponent("usage.json").path))
            try FileManager.default.removeItem(
                at: home.appendingPathComponent(".claude/projects/mock/session.jsonl"))
            let restarted = try await collect(home, data)
            #expect(
                try UsageNativeJSON.encode(restarted["totals"]!) == UsageNativeJSON.encode(totals))
            let archive = try UsageNativeArchive(dataDirectory: data)
            let stored = try archive.database.rows("SELECT payload FROM records").map {
                $0["payload"] ?? ""
            }.joined()
            #expect(!stored.contains("PRIVATE_CONTENT_CANARY"))
            #expect(!stored.contains("secret@"))
        }
    }

    @Test func openCodeSQLiteProjectionMatchesFileAndDoesNotDuplicate() async throws {
        try await fixture { home, data in
            let root = home.appendingPathComponent(".local/share/opencode")
            try UsageNativeFileIO.privateDirectory(root)
            let database = try UsageNativeDatabase(url: root.appendingPathComponent("opencode.db"))
            try database.execute(
                "CREATE TABLE session(id TEXT PRIMARY KEY,directory TEXT,title TEXT); CREATE TABLE message(id TEXT PRIMARY KEY,session_id TEXT,data TEXT)"
            )
            let row = openCodeRow(id: "same", cwd: "/mock/project")
            try database.run(
                "INSERT INTO session VALUES(?,?,?)",
                ["mock-opencode", "/mock/project", "Mock title"])
            try database.run(
                "INSERT INTO message VALUES(?,?,?)",
                [
                    "same", "mock-opencode",
                    String(decoding: try UsageNativeJSON.encode(row), as: UTF8.self),
                ])
            database.close()
            try write(
                try UsageNativeJSON.encode(row),
                root.appendingPathComponent("storage/message/mock/same.json"))
            let value = try await collect(home, data)
            try validate(value)
            #expect((value["totals"] as? [String: Any])?["tokens"] as? Double == 8)
        }
    }

    @Test func modernReceiptsReplaceLegacyAccountingInSameJournal() async throws {
        try await fixture { home, data in
            let file = home.appendingPathComponent(".codex/sessions/session.jsonl")
            let start: [[String: Any]] = [
                ["type": "session_meta", "payload": ["id": "session"]],
                [
                    "type": "event_msg", "timestamp": "2026-09-05T02:00:00Z",
                    "payload": [
                        "type": "token_count",
                        "info": ["total_token_usage": ["input_tokens": 10, "output_tokens": 2]],
                    ],
                ],
            ]
            try write(try lines(start), file)
            #expect(
                (try await collect(home, data)["totals"] as? [String: Any])?["tokens"] as? Double
                    == 12)
            let modern: [String: Any] = [
                "type": "token_usage_record", "timestamp": "2026-09-05T02:00:00Z",
                "payload": [
                    "response_id": "response-one",
                    "usage": ["input_tokens": 10, "output_tokens": 2],
                ],
            ]
            try write(try lines(start + [modern]), file)
            #expect(
                (try await collect(home, data)["totals"] as? [String: Any])?["tokens"] as? Double
                    == 12)
        }
    }

    @Test func completeCollectionNeverStartsNetworkWhenOffline() async throws {
        try await fixture { home, data in
            try write(
                try UsageNativeJSON.encode(["tokens": ["access_token": "mock-token"]]),
                home.appendingPathComponent(".codex/auth.json"))
            let network = UsageNativeNetwork { _ in
                throw UsageNativeFailure.invalidInput("unexpected request")
            }
            let value = try await collect(home, data, network: network)
            try validate(value)
            #expect((value["daily"] as? [Any])?.isEmpty == true)
        }
    }

    @Test func cloudAnalyticsPreserveDateInWesternTimezoneWithoutInventedHours() async throws {
        try await fixture { home, data in
            let archive = try UsageNativeArchive(dataDirectory: data)
            let events = try UsageNativeCloud.normalizeCodex(codexCloud())
            let value = try UsageNativeAssembly.document(
                events: events, archive: archive, now: Date(),
                timezone: TimeZone(identifier: "America/Los_Angeles")!,
                cloudSources: ["codex-cloud"])
            try validate(value)
            let day = try #require((value["daily"] as? [[String: Any]])?.first)
            #expect(day["period"] as? String == "2025-05-16")
            #expect(
                (day["hours"] as? [[String: Any]])?.allSatisfy { $0["tokens"] as? Double == 0 }
                    == true)
            #expect((day["projects"] as? [Any])?.isEmpty == true)
        }
    }

    @Test func cloudAnalyticsRejectMismatchedTokensDuplicateClientsAndInvalidDays() throws {
        var response = codexCloud()
        var days = response["data"] as! [[String: Any]]
        var clients = days[0]["clients"] as! [[String: Any]]
        clients[0]["text_total_tokens"] = 99
        days[0]["clients"] = clients; response["data"] = days
        #expect(throws: UsageNativeFailure.self) { try UsageNativeCloud.normalizeCodex(response) }
        response = codexCloud(); days = response["data"] as! [[String: Any]]
        clients = days[0]["clients"] as! [[String: Any]]
        days[0]["clients"] = clients + clients; response["data"] = days
        #expect(throws: UsageNativeFailure.self) { try UsageNativeCloud.normalizeCodex(response) }
        days[0]["date"] = "2025-02-31"; response["data"] = days
        #expect(throws: UsageNativeFailure.self) { try UsageNativeCloud.normalizeCodex(response) }
    }

    @Test func cloudAnalyticsIgnoreDesktopReceiptsAndUseRecordedDollarCost() throws {
        var response = codexCloud()
        var days = response["data"] as! [[String: Any]]
        var entries = days[0]["clients"] as! [[String: Any]]
        entries[0]["cost_usd"] = "1.25"
        var desktop = entries[0]; desktop["client_id"] = "CODEX_DESKTOP"
        days[0]["clients"] = entries + [desktop]; response["data"] = days
        let events = try UsageNativeCloud.normalizeCodex(response)
        #expect(events.count == 1)
        #expect(events[0].recordedCost == 1.25)
    }

    @Test func remoteSnapshotsReplaceCorrectionsAndAccountsWithoutAccumulating() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "usage-native-remote-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = try UsageNativeArchive(dataDirectory: root)
        var receipt = try UsageNativeCloud.normalizeCodex(codexCloud())[0]
        try archive.replaceRemote([receipt], key: "remote:codex-cloud", account: "one")
        receipt.recordedCost = 0.1
        try archive.replaceRemote([receipt], key: "remote:codex-cloud", account: "one")
        #expect(try archive.events().count == 1)
        #expect(try archive.events().first?.recordedCost == 0.1)
        try archive.replaceRemote([], key: "remote:codex-cloud", account: "two")
        #expect(try archive.events().isEmpty)
    }

    @Test func cancelledCollectionStopsBeforeCreatingArchive() async throws {
        try await fixture { home, data in
            let task = Task {
                try await Task.sleep(for: .seconds(10))
                return try await collect(home, data)
            }
            task.cancel()
            do {
                _ = try await task.value; Issue.record("Cancelled collection completed")
            } catch is CancellationError {}
            #expect(
                !FileManager.default.fileExists(
                    atPath: data.appendingPathComponent("native-usage-history").path))
        }
    }

    @Test func networkRejectsOversizedBodiesAndRedirectResponses() async throws {
        let request = URLRequest(url: URL(string: "https://example.invalid/mock")!)
        let large = UsageNativeNetwork(maximumBytes: 8) { _ in (Data(repeating: 65, count: 9), 200)
        }
        do {
            _ = try await large.object(request); Issue.record("Oversized body admitted")
        } catch UsageNativeFailure.capacity {}
        let redirect = UsageNativeNetwork { _ in (Data("{}".utf8), 302) }
        do {
            _ = try await redirect.object(request); Issue.record("Redirect response admitted")
        } catch UsageNativeFailure.network(let status) { #expect(status == 302) }
    }

    @Test func openCodeV2DatabaseUsesMessageTimeAndSessionDirectory() async throws {
        try await fixture { home, data in
            let root = home.appendingPathComponent(".local/share/opencode")
            try UsageNativeFileIO.privateDirectory(root)
            let database = try UsageNativeDatabase(url: root.appendingPathComponent("opencode.db"))
            try database.execute(
                "CREATE TABLE session_v2(id TEXT,directory TEXT,title TEXT); CREATE TABLE session_message(id TEXT,session_id TEXT,type TEXT,time_created INTEGER,data TEXT)"
            )
            try database.run(
                "INSERT INTO session_v2 VALUES(?,?,?)",
                ["mock-v2-session", "/mock/project", "Mock title"])
            let payload: [String: Any] = [
                "model": ["id": "gpt-5"],
                "tokens": [
                    "input": 4, "output": 2, "reasoning": 3, "cache": ["read": 1, "write": 2],
                ], "cost": 0.5, "content": "PRIVATE_CONTENT_CANARY",
            ]
            try database.run(
                "INSERT INTO session_message VALUES(?,?,?,?,?)",
                [
                    "mock-v2-message", "mock-v2-session", "assistant", 1_788_570_000_000,
                    String(decoding: try UsageNativeJSON.encode(payload), as: UTF8.self),
                ]);
            database.close()
            let result = try await collect(home, data)
            try validate(result)
            #expect((result["totals"] as? [String: Any])?["tokens"] as? Double == 12)
            #expect((result["totals"] as? [String: Any])?["cost"] as? Double == 0.5)
            let day = try #require((result["daily"] as? [[String: Any]])?.first)
            #expect(
                (day["projects"] as? [[String: Any]])?.first?["path"] as? String == "/mock/project")
        }
    }

    private func collect(_ home: URL, _ data: URL, network: UsageNativeNetwork = .init())
        async throws -> [String: Any]
    {
        try UsageNativeJSON.object(
            await UsageNativeCollector.collect(
                home: home, dataDirectory: data,
                environment: ["EDITH_USAGE_OFFLINE": "1", "TZ": "UTC"],
                now: Date(timeIntervalSince1970: 1_788_566_400), network: network, onEvent: { _ in }
            ))
    }

    private func claude(id: String, cwd: String) -> Data {
        try! lines([
            [
                "timestamp": "2026-09-05T01:00:00Z", "sessionId": "mock-claude",
                "requestId": "request", "cwd": cwd, "costUSD": 1,
                "message": [
                    "id": id, "model": "claude-sonnet-4-5",
                    "usage": ["input_tokens": 10, "output_tokens": 2],
                    "content": "PRIVATE_CONTENT_CANARY",
                ],
            ]
        ])
    }

    private func openCodeRow(id: String, cwd: String) -> [String: Any] {
        [
            "id": id, "sessionID": "mock-opencode", "role": "assistant", "modelID": "gpt-5",
            "path": ["cwd": cwd],
            "time": ["created": 1_788_573_600_000], "cost": 1,
            "tokens": ["input": 5, "output": 2, "reasoning": 1, "cache": ["read": 0, "write": 0]],
            "privatePrompt": "PRIVATE_CONTENT_CANARY",
        ]
    }

    private func codexCloud() -> [String: Any] {
        [
            "group_by": "day", "balance_unit": "credit",
            "data": [
                [
                    "date": "2025-05-16",
                    "clients": [
                        [
                            "client_id": "CODEX_WEB", "uncached_text_input_tokens": 10,
                            "cached_text_input_tokens": 5, "text_output_tokens": 2,
                            "text_total_tokens": 17, "credits": 10,
                        ]
                    ],
                ]
            ],
        ]
    }

    private func lines(_ rows: [[String: Any]]) throws -> Data {
        try rows.reduce(into: Data()) { result, row in
            result += try UsageNativeJSON.encode(row); result.append(10)
        }
    }

    private func write(_ value: Data, _ path: URL) throws {
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try value.write(to: path)
    }

    private func fixture(_ action: (URL, URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "usage-native-collector-" + UUID().uuidString)
        try UsageNativeFileIO.privateDirectory(root)
        defer { try? FileManager.default.removeItem(at: root) }
        try await action(root.appendingPathComponent("home"), root.appendingPathComponent("data"))
    }

    private func validate(_ root: [String: Any]) throws {
        #expect(root["schemaVersion"] as? Int == 8)
        let days = try #require(root["daily"] as? [[String: Any]])
        let totals = try #require(root["totals"] as? [String: Any])
        let sources = try #require(root["sources"] as? [String])
        #expect(Set(sources).count == sources.count)
        #expect((root["defaultSources"] as? [String] ?? []).allSatisfy(sources.contains))
        #expect(
            days.compactMap { $0["period"] as? String }
                == days.compactMap { $0["period"] as? String }.sorted())
        var tokens = 0.0; var cost = 0.0
        for day in days {
            let rows = try #require(day["bySource"] as? [String: [[String: Any]]])
            for model in rows.values.flatMap({ $0 }) {
                for field in [
                    "inputTokens", "outputTokens", "cacheCreationTokens", "cacheReadTokens", "cost",
                ] {
                    let value = try #require(model[field] as? Double)
                    #expect(value >= 0 && value.isFinite)
                    if field == "cost" { cost += value } else { tokens += value }
                }
            }
            let hours = try #require(day["hours"] as? [[String: Any]])
            #expect(hours.count == 24)
            #expect(
                hours.reduce(0.0) { $0 + ($1["tokens"] as? Double ?? 0) }
                    <= rows.values.flatMap({ $0 }).reduce(0.0) {
                        $0 + ($1["tokens"] as? Double ?? 0)
                    })
            for node in hours + (day["projects"] as? [[String: Any]] ?? []) {
                let breakdown = try #require(node["bySource"] as? [String: [String: Any]])
                #expect(
                    node["tokens"] as? Double
                        == breakdown.values.reduce(0.0) { $0 + ($1["tokens"] as? Double ?? 0) })
                for source in breakdown.values {
                    let models = try #require(source["byModel"] as? [String: [String: Any]])
                    #expect(
                        source["tokens"] as? Double
                            == models.values.reduce(0.0) { $0 + ($1["tokens"] as? Double ?? 0) })
                }
            }
        }
        #expect(totals["tokens"] as? Double == tokens)
        #expect(abs((totals["cost"] as? Double ?? 0) - cost) < 0.000001)
    }
}
