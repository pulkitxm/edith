import Foundation
import Testing
@testable import UsageExtension

@Suite(.serialized) struct UsageNativeProviderTests {
    @Test(arguments: ["amp", "droid", "gemini", "qwen", "kimi", "copilot", "codebuff"])
    func supplementalProviderReceiptsPreserveTokensWithoutPrivateContent(source: String) throws {
        let context = UsageNativeProviderFormats.Context(
            source: source, session: "mock-session", cwd: "/mock/project",
            title: nil, model: "gpt-5", timestamp: UsageNativeJSON.date("2026-09-05T01:00:00Z")!)
        let events = try #require(
            try UsageNativeProviderFormats.document(receipt(source), context: context))
        #expect(events.count == 1)
        #expect(events[0].source == source)
        #expect(events[0].tokens.total > 0)
        #expect(
            !String(decoding: try events[0].canonicalData, as: UTF8.self).contains(
                "PRIVATE_CONTENT_CANARY"))
        #expect(events[0].timestamp == context.timestamp)
    }

    @Test func kimiSessionTotalsAreExcludedWhileTurnReceiptsCount() throws {
        var row = receipt("kimi") as! [String: Any]
        row["usageScope"] = "session"
        let context = UsageNativeProviderFormats.Context(
            source: "kimi", session: "mock", cwd: "", title: nil, model: "gpt-5", timestamp: Date())
        #expect(try UsageNativeProviderFormats.document(row, context: context)?.isEmpty == true)
    }

    @Test func ampLedgerWinsOverMessageUsageAndRestoresPromptCacheCounts() throws {
        let value: [String: Any] = [
            "id": "thread",
            "messages": [
                [
                    "role": "assistant", "messageId": 1,
                    "usage": ["inputTokens": 100, "outputTokens": 20, "cacheReadInputTokens": 5],
                ]
            ],
            "usageLedger": [
                "events": [
                    [
                        "id": "request", "toMessageId": 1, "model": "gpt-5",
                        "timestamp": "2026-09-05T01:00:00Z", "tokens": ["input": 10, "output": 2],
                    ]
                ]
            ],
        ]
        let context = UsageNativeProviderFormats.Context(
            source: "amp", session: "mock", cwd: "", title: nil, model: "gpt-5", timestamp: Date())
        let events = try #require(try UsageNativeProviderFormats.document(value, context: context))
        #expect(events.count == 1)
        #expect(events[0].tokens.input == 10)
        #expect(events[0].tokens.read == 5)
        #expect(events[0].tokens.total == 17)
    }

    @Test func geminiInclusiveCachedTotalsAndStatsDoNotDoubleCountPrompt() throws {
        let context = UsageNativeProviderFormats.Context(
            source: "gemini", session: "mock", cwd: "", title: nil, model: "gemini-2.5-pro",
            timestamp: Date())
        let direct: [String: Any] = [
            "type": "gemini",
            "tokens": ["input": 10, "output": 2, "cached": 5, "thoughts": 3, "total": 15],
        ]
        let receipt = try #require(
            try UsageNativeProviderFormats.document(direct, context: context)?.first)
        #expect(receipt.tokens.input == 5)
        #expect(receipt.tokens.output == 5)
        #expect(receipt.tokens.total == 15)
        let stats: [String: Any] = [
            "stats": [
                "models": [
                    "gemini-2.5-pro": [
                        "tokens": [
                            "input": 10, "output": 2, "cached": 5, "thoughts": 3, "total": 15,
                        ]
                    ]
                ]
            ]
        ]
        let aggregate = try #require(
            try UsageNativeProviderFormats.document(stats, context: context)?.first)
        #expect(aggregate.tokens == receipt.tokens)
    }

    @Test func nativeDatabaseOnlyProvidersProjectUsageAndRetainDeletedDatabases() throws {
        try fixture { home, data in
            let hermes = try database(home.appendingPathComponent(".hermes/state.db"))
            try hermes.execute(
                "CREATE TABLE sessions(id TEXT,model TEXT,started_at REAL,input_tokens INTEGER,output_tokens INTEGER,cache_read_tokens INTEGER,cache_write_tokens INTEGER,reasoning_tokens INTEGER,actual_cost_usd REAL)"
            )
            try hermes.run(
                "INSERT INTO sessions VALUES(?,?,?,?,?,?,?,?,?)",
                ["hermes-session", "gpt-5", 1_788_573_600.0, 10, 2, 3, 1, 4, 1.25]);
            hermes.close()
            let goose = try database(
                home.appendingPathComponent(".local/share/goose/sessions/sessions.db"))
            try goose.execute(
                "CREATE TABLE sessions(id TEXT,model_config_json TEXT,created_at TEXT,input_tokens INTEGER,output_tokens INTEGER,total_tokens INTEGER,accumulated_input_tokens INTEGER,accumulated_output_tokens INTEGER,accumulated_total_tokens INTEGER)"
            )
            try goose.run(
                "INSERT INTO sessions VALUES(?,?,?,?,?,?,?,?,?)",
                [
                    "goose-session", "{\"model_name\":\"gpt-5\"}", "2026-09-05 01:00:00", 1, 2, 3,
                    10, 2, 15,
                ]);
            goose.close()
            let kilo = try database(home.appendingPathComponent(".local/share/kilo/kilo.db"))
            try kilo.execute("CREATE TABLE message(id TEXT,session_id TEXT,data TEXT)")
            let payload: [String: Any] = [
                "role": "assistant", "modelID": "gpt-5", "time": ["created": 1_788_573_600_000],
                "tokens": [
                    "input": 10, "output": 2, "reasoning": 3, "cache": ["read": 1, "write": 2],
                ], "cost": 1, "content": "PRIVATE_CONTENT_CANARY",
            ]
            try kilo.run(
                "INSERT INTO message VALUES(?,?,?)",
                [
                    "kilo-one", "kilo-session",
                    String(decoding: try UsageNativeJSON.encode(payload), as: UTF8.self),
                ]);
            kilo.close()
            let archive = try UsageNativeArchive(dataDirectory: data)
            try UsageNativeProviderDatabases.collect(home: home, environment: [:], archive: archive)
            let events = try archive.events()
            #expect(Set(events.map(\.source)) == ["hermes", "goose", "kilo"])
            #expect(events.first { $0.source == "hermes" }?.tokens.total == 20)
            #expect(events.first { $0.source == "hermes" }?.recordedCost == 1.25)
            #expect(events.first { $0.source == "goose" }?.tokens.total == 15)
            #expect(events.first { $0.source == "kilo" }?.tokens.total == 18)
            let stored = try archive.database.rows("SELECT payload FROM records").map {
                $0["payload"] ?? ""
            }.joined()
            #expect(!stored.contains("PRIVATE_CONTENT_CANARY"))
            try FileManager.default.removeItem(at: home)
            try UsageNativeProviderDatabases.collect(home: home, environment: [:], archive: archive)
            #expect(try archive.events().count == 3)
        }
    }

    @Test func fileDiscoveryHandlesConfiguredProviderRootsAndContainers() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "usage-native-formats-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let data = root.appendingPathComponent("data")
        let files = [
            "amp": ".local/share/amp/threads/thread.json",
            "droid": ".factory/sessions/session.settings.json",
            "gemini": ".gemini/tmp/mock/chats/session.json",
            "qwen": ".qwen/projects/mock/chats/session.jsonl",
            "kimi": ".kimi/sessions/mock/session/wire.jsonl",
            "copilot": ".copilot/session-state/session/events.jsonl",
            "codebuff": ".config/manicode/projects/mock/chats/session/chat-messages.json",
        ]
        for (source, path) in files {
            let location = home.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: location.deletingLastPathComponent(), withIntermediateDirectories: true)
            var encoded = try UsageNativeJSON.encode(receipt(source))
            if location.pathExtension == "jsonl" { encoded.append(10) }
            try encoded.write(to: location)
        }
        let document = try await UsageNativeCollector.collect(
            home: home, dataDirectory: data,
            environment: ["EDITH_USAGE_OFFLINE": "1", "TZ": "UTC"], onEvent: { _ in })
        let value = try UsageNativeJSON.object(document)
        #expect(Set(value["sources"] as? [String] ?? []) == Set(files.keys))
        #expect((value["daily"] as? [[String: Any]])?.first?["period"] as? String == "2026-09-05")
    }

    private func receipt(_ source: String) -> Any {
        let date = "2026-09-05T01:00:00Z"
        switch source {
        case "amp":
            return [
                "id": "mock-thread",
                "messages": [
                    [
                        "role": "assistant", "messageId": "mock-message", "model": "gpt-5",
                        "timestamp": date, "usage": ["inputTokens": 10, "outputTokens": 2],
                    ]
                ], "content": "PRIVATE_CONTENT_CANARY",
            ] as [String: Any]
        case "droid":
            return [
                "model": "gpt-5", "providerLockTimestamp": date,
                "tokenUsage": ["inputTokens": 10, "outputTokens": 2],
                "content": "PRIVATE_CONTENT_CANARY",
            ] as [String: Any]
        case "gemini":
            return [
                "sessionId": "mock-session",
                "messages": [
                    [
                        "type": "gemini", "model": "gemini-2.5-pro", "timestamp": date,
                        "tokens": [
                            "input": 10, "output": 2, "cached": 3, "thoughts": 1, "total": 16,
                        ],
                    ]
                ],
            ] as [String: Any]
        case "qwen":
            return [
                "type": "assistant", "timestamp": date, "model": "qwen-plus",
                "usageMetadata": [
                    "promptTokenCount": 10, "candidatesTokenCount": 2, "cachedContentTokenCount": 3,
                    "thoughtsTokenCount": 1, "totalTokenCount": 16,
                ],
            ] as [String: Any]
        case "kimi":
            return [
                "type": "usage.record", "usageScope": "turn", "time": 1_788_570_000_000,
                "model": "kimi-for-coding",
                "usage": ["inputOther": 10, "output": 2, "inputCacheRead": 3],
            ] as [String: Any]
        case "copilot":
            return [
                "type": "session.shutdown", "timestamp": date,
                "data": [
                    "modelMetrics": [
                        "gpt-5": [
                            "usage": [
                                "inputTokens": 10, "outputTokens": 2, "cacheReadTokens": 3,
                                "cacheWriteTokens": 1, "reasoningTokens": 1,
                            ]
                        ]
                    ]
                ],
            ] as [String: Any]
        default:
            return [
                [
                    "variant": "ai", "timestamp": date,
                    "metadata": [
                        "model": "gpt-5", "usage": ["inputTokens": 10, "outputTokens": 2],
                    ], "content": "PRIVATE_CONTENT_CANARY",
                ]
            ] as [[String: Any]]
        }
    }
    private func database(_ path: URL) throws -> UsageNativeDatabase {
        try UsageNativeFileIO.privateDirectory(path.deletingLastPathComponent())
        return try UsageNativeDatabase(url: path)
    }
    private func fixture(_ action: (URL, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "usage-native-dbformats-" + UUID().uuidString)
        try UsageNativeFileIO.privateDirectory(root)
        defer { try? FileManager.default.removeItem(at: root) }
        try action(root.appendingPathComponent("home"), root.appendingPathComponent("data"))
    }
}
