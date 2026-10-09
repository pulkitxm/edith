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

    @Test func telemetryChatReceiptsWinOverInferenceAndSummaryObservations() throws {
        let context = UsageNativeProviderFormats.Context(
            source: "copilot", session: "mock-session", cwd: "", title: nil, model: "unknown",
            timestamp: Date())
        func row(kind: String, input: Int) -> [String: Any] {
            [
                "type": "span", "name": kind + " gpt-5", "traceId": "trace", "spanId": kind,
                "startTime": [1_788_570_000, 0],
                "attributes": [
                    "gen_ai.operation.name": kind,
                    "gen_ai.conversation.id": "mock-session", "gen_ai.response.id": "response",
                    "gen_ai.response.model": "gpt-5",
                    "gen_ai.usage.input_tokens": input, "gen_ai.usage.output_tokens": 2,
                    "gen_ai.usage.cache_read.input_tokens": 3,
                ],
            ]
        }
        let primary = try #require(
            try UsageNativeProviderFormats.document(row(kind: "chat", input: 10), context: context)?
                .first)
        let summary = try #require(
            try UsageNativeProviderFormats.document(
                row(kind: "invoke_agent", input: 100), context: context)?.first)
        var inference = row(kind: "chat", input: 10)
        inference["type"] = "log"; inference.removeValue(forKey: "name")
        var attributes = inference["attributes"] as! [String: Any]
        attributes.removeValue(forKey: "gen_ai.operation.name")
        attributes["event.name"] = "gen_ai.client.inference.operation.details";
        inference["attributes"] = attributes
        let secondary = try #require(
            try UsageNativeProviderFormats.document(inference, context: context)?.first)
        let shutdown = try #require(
            try UsageNativeProviderFormats.document(receipt("copilot"), context: context)?.first)
        let events = UsageNativeAssembly.deduplicate([summary, secondary, primary, shutdown])
        #expect(events.count == 1)
        #expect(events[0].tokens.input == 7)
        #expect(events[0].tokens.total == 12)
        #expect(events[0].model == "gpt-5")
    }

    @Test func nativeOpenClawDatabaseProjectsReceiptsWithoutConversationContent() throws {
        try fixture { home, data in
            let store = try database(
                home.appendingPathComponent(".openclaw/agents/main/agent/openclaw-agent.sqlite"))
            try store.execute(
                "CREATE TABLE transcript_events(session_id TEXT,seq INTEGER,event_json TEXT,created_at INTEGER)"
            )
            let row: [String: Any] = [
                "id": "mock-event", "type": "message",
                "message": [
                    "role": "assistant", "model": "gpt-5", "timestamp": 1_788_570_000_000,
                    "usage": ["input": 10, "output": 2, "cost": ["total": 0.5]],
                    "content": "PRIVATE_CONTENT_CANARY",
                ],
            ]
            try store.run(
                "INSERT INTO transcript_events VALUES(?,?,?,?)",
                [
                    "mock-session", 0,
                    String(decoding: try UsageNativeJSON.encode(row), as: UTF8.self),
                    1_788_570_000_000,
                ]);
            store.close()
            let archive = try UsageNativeArchive(dataDirectory: data)
            try UsageNativeProviderDatabases.collect(home: home, environment: [:], archive: archive)
            let event = try #require(try archive.events().first)
            #expect(event.source == "openclaw")
            #expect(event.tokens.total == 12)
            #expect(event.recordedCost == 0.5)
            #expect(
                !String(decoding: try event.canonicalData, as: UTF8.self).contains(
                    "PRIVATE_CONTENT_CANARY"))
        }
    }

    @Test func numericWireCountsAndTimestampAdmissionRemainStrict() throws {
        #expect(try UsageNativeTokens.wireNumber("100") == 100)
        for value: Any in ["1e4", "-1", "1.5", "01", true, "9999999999999999"] {
            #expect(throws: UsageNativeFailure.self) { try UsageNativeTokens.wireNumber(value) }
        }
        #expect(UsageNativeJSON.date(true) == nil)
        #expect(UsageNativeJSON.date(Double.greatestFiniteMagnitude) == nil)
    }

    @Test func everyOriginalProviderCollectsIntoOneCompleteSchemaWithoutHelperProcesses()
        async throws
    {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "usage-native-all-sources-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let data = root.appendingPathComponent("data")
        func write(_ value: Any, _ name: String) throws {
            let file = home.appendingPathComponent(name)
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            var encoded = try UsageNativeJSON.encode(value)
            if file.pathExtension == "jsonl" { encoded.append(10) }
            try encoded.write(to: file)
        }
        let files = [
            "amp": ".local/share/amp/threads/thread.json",
            "droid": ".factory/sessions/session.settings.json",
            "gemini": ".gemini/tmp/mock/chats/session.json",
            "qwen": ".qwen/projects/mock/chats/session.jsonl",
            "kimi": ".kimi/sessions/mock/session/wire.jsonl",
            "copilot": ".copilot/session-state/session/events.jsonl",
            "codebuff": ".config/manicode/projects/mock/chats/session/chat-messages.json",
        ]
        for (source, name) in files { try write(receipt(source), name) }
        func assistant(_ id: String) -> [String: Any] {
            [
                "type": "assistant", "timestamp": "2026-09-05T01:00:00Z", "sessionId": "mock-" + id,
                "requestId": id,
                "message": [
                    "id": id, "model": "claude-sonnet-4-5",
                    "usage": ["input_tokens": 10, "output_tokens": 2],
                ],
            ]
        }
        try write(assistant("local"), ".claude/projects/mock/session.jsonl")
        try write(
            assistant("cowork"),
            "Library/Application Support/Claude/local-agent-mode-sessions/mock/.claude/projects/session.jsonl"
        )
        let codexFile = home.appendingPathComponent(".codex/sessions/session.jsonl")
        try FileManager.default.createDirectory(
            at: codexFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        let codexRows: [[String: Any]] = [
            ["type": "session_meta", "payload": ["id": "mock-native-session"]],
            [
                "type": "token_usage_record", "timestamp": "2026-09-05T01:00:00Z",
                "payload": [
                    "response_id": "mock-response", "model": "gpt-5",
                    "usage": ["input_tokens": 10, "output_tokens": 2],
                ],
            ],
        ]
        try codexRows.reduce(into: Data()) {
            $0 += try UsageNativeJSON.encode($1); $0.append(10)
        }.write(to: codexFile)
        try write(
            [
                "timestamp": "2026-09-05T01:00:00Z", "model": "gpt-5",
                "conversationId": "mock-cursor",
                "tokenUsage": ["inputTokens": 10, "outputTokens": 2], "chargedCents": 25,
            ], ".cursor/chats/mock/usage.jsonl")
        let opencode: [String: Any] = [
            "id": "mock-opencode", "sessionID": "mock-session", "role": "assistant",
            "modelID": "gpt-5", "time": ["created": 1_788_570_000_000],
            "tokens": ["input": 10, "output": 2], "cost": 0.5,
        ]
        try write(opencode, ".local/share/opencode/storage/message/mock/message.json")
        for (source, name) in [
            "pi": ".pi/agent/sessions/mock.jsonl",
            "commandcode": ".commandcode/projects/mock.jsonl",
            "openclaw": ".openclaw/agents/mock/sessions/mock.jsonl",
        ] {
            try write(
                [
                    "type": "message", "id": source + "-message",
                    "timestamp": "2026-09-05T01:00:00Z", "sessionId": source + "-session",
                    "message": [
                        "role": "assistant", "model": "gpt-5",
                        "usage": ["input": 10, "output": 2, "cost": ["total": 0.5]],
                    ],
                ], name)
        }
        try write(
            [
                "params": [
                    "sessionId": "mock-grok", "_meta": ["agentTimestampMs": 1_788_570_000_000],
                    "update": [
                        "sessionUpdate": "turn_completed",
                        "usage": [
                            "inputTokens": 10, "outputTokens": 2, "costUsdTicks": 5_000_000_000,
                        ],
                    ],
                ]
            ], ".grok/sessions/%2Fmock%2Fproject/mock/updates.jsonl")
        let hermes = try database(home.appendingPathComponent(".hermes/state.db"))
        try hermes.execute(
            "CREATE TABLE sessions(id TEXT,model TEXT,started_at REAL,input_tokens INTEGER,output_tokens INTEGER)"
        )
        try hermes.run(
            "INSERT INTO sessions VALUES(?,?,?,?,?)",
            ["mock-hermes", "gpt-5", 1_788_570_000.0, 10, 2]);
        hermes.close()
        let goose = try database(
            home.appendingPathComponent(".local/share/goose/sessions/sessions.db"))
        try goose.execute(
            "CREATE TABLE sessions(id TEXT,model_config_json TEXT,created_at TEXT,input_tokens INTEGER,output_tokens INTEGER,total_tokens INTEGER)"
        )
        try goose.run(
            "INSERT INTO sessions VALUES(?,?,?,?,?,?)",
            ["mock-goose", "{\"model_name\":\"gpt-5\"}", "2026-09-05T01:00:00Z", 10, 2, 12]);
        goose.close()
        let kilo = try database(home.appendingPathComponent(".local/share/kilo/kilo.db"))
        try kilo.execute("CREATE TABLE message(id TEXT,session_id TEXT,data TEXT)")
        try kilo.run(
            "INSERT INTO message VALUES(?,?,?)",
            [
                "mock-kilo", "mock-session",
                String(decoding: try UsageNativeJSON.encode(opencode), as: UTF8.self),
            ]);
        kilo.close()
        try write(
            [
                "claudeAiOauth": [
                    "accessToken": "mock-cloud-token", "scopes": ["user:sessions:claude_code"],
                ]
            ], ".claude/.credentials.json")
        try write(
            ["tokens": ["access_token": "mock-codex-token", "account_id": "mock-account"]],
            ".codex/auth.json")
        let network = UsageNativeNetwork { request in
            if request.url!.host == "api.anthropic.com" {
                let payload: [String: Any] =
                    request.url!.path.hasSuffix("teleport-events")
                    ? ["data": [["payload": assistant("cloud")]]]
                    : ["data": [["id": "mock-session", "last_event_at": "one"]]]
                return (try UsageNativeJSON.encode(payload), 200)
            }
            #expect(request.url!.host == "chatgpt.com")
            let date = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
                .first { $0.name == "start_date" }!.value!
            return (
                try UsageNativeJSON.encode([
                    "group_by": "day",
                    "data": [
                        [
                            "date": date,
                            "clients": [
                                [
                                    "client_id": "CODEX_WEB", "uncached_text_input_tokens": 10,
                                    "cached_text_input_tokens": 0, "text_output_tokens": 2,
                                    "text_total_tokens": 12, "cost_usd": 0.5,
                                ]
                            ],
                        ]
                    ],
                ]), 200
            )
        }
        let document = try await UsageNativeCollector.collect(
            home: home, dataDirectory: data, environment: ["TZ": "UTC"],
            now: UsageNativeJSON.date("2026-09-06T00:00:00Z")!, network: network, onEvent: { _ in })
        let result = try UsageNativeJSON.object(document)
        #expect(Set(result["sources"] as? [String] ?? []) == Set(UsageNativeAssembly.labels.keys))
        #expect((result["sources"] as? [String])?.count == 21)
        #expect(
            (result["daily"] as? [[String: Any]])?.allSatisfy {
                ($0["hours"] as? [Any])?.count == 24
            } == true)
        #expect(
            !FileManager.default.fileExists(atPath: data.appendingPathComponent("usage.json").path))
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
