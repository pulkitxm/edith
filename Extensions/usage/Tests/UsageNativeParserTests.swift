import Foundation
import Testing
@testable import UsageExtension

@Suite(.serialized) struct UsageNativeParserTests {
    @Test func grokModelReceiptsSubtractCachedInputAndPreserveDollarTicks() throws {
        let row: [String: Any] = ["params": ["sessionId": "mock-session", "_meta": ["agentTimestampMs": 1_788_573_600_000],
            "update": ["sessionUpdate": "turn_completed", "usage": ["modelUsage": [
                "grok-4": ["inputTokens": 20, "cachedReadTokens": 5, "cacheCreationTokens": 3, "outputTokens": 2, "costUsdTicks": 5_000_000_000],
                "grok-4-fast": ["inputTokens": 2, "outputTokens": 1, "costUsdTicks": 1_000_000_000],
            ]]]]]
        let events = try UsageNativeParser(source: "grok").consume(row).map(\.event)
        #expect(events.count == 2)
        #expect(events[0].tokens.input == 12)
        #expect(events[0].tokens.total == 22)
        #expect(events[0].recordedCost == 0.5)
        #expect(Set(events.compactMap(\.identity)).count == 2)
    }

    @Test func promptCacheCreationMismatchRejectsInvalidGrokReceipt() throws {
        let row: [String: Any] = ["params": ["sessionId": "mock", "_meta": ["agentTimestampMs": 1_788_573_600_000],
            "update": ["sessionUpdate": "turn_completed", "usage": ["inputTokens": 2, "cachedReadTokens": 5]]]]
        #expect(throws: UsageNativeFailure.self) { try UsageNativeParser(source: "grok").consume(row) }
    }

    @Test func modernReceiptsDeduplicateReplayAndReplaceLegacyTotals() throws {
        try snapshot([
            meta,
            context,
            [
                "type": "event_msg", "timestamp": stamp,
                "payload": [
                    "type": "token_count",
                    "info": ["total_token_usage": ["input_tokens": 1000, "output_tokens": 100]],
                ],
            ],
            modern("first", input: 100), modern("first", input: 100), modern("second", input: 100),
        ]) { records in
            #expect(records.count == 2)
            #expect(records.map { $0.event.tokens.total }.reduce(0, +) == 220)
            #expect(Set(records.compactMap { $0.event.identity }) == ["first", "second"])
            #expect(records.allSatisfy { $0.event.model == "gpt-6.1-sol" })
        }
    }

    @Test func modernReceiptsRejectInvalidTokensAndIgnoreOtherThreads() throws {
        try snapshot([meta, context, modern("other", thread: "other")]) { #expect($0.isEmpty) }
        #expect(throws: UsageNativeFailure.self) {
            try snapshot([meta, context, modern("invalid", input: -1)]) { _ in }
        }
    }

    @Test func cumulativeLegacyTotalsAdvanceOnceAndCachedTokensAreNotDoubleCounted() throws {
        func legacy(_ input: Int, _ output: Int, _ cached: Int) -> [String: Any] {
            [
                "type": "event_msg", "timestamp": stamp,
                "payload": [
                    "type": "token_count",
                    "info": [
                        "total_token_usage": [
                            "input_tokens": input, "output_tokens": output,
                            "cached_input_tokens": cached,
                        ]
                    ],
                ],
            ]
        }
        try snapshot([meta, context, legacy(100, 10, 60), legacy(100, 10, 60), legacy(150, 20, 80)])
        { records in
            #expect(records.count == 2)
            #expect(records.map { $0.event.tokens.input }.reduce(0, +) == 70)
            #expect(records.map { $0.event.tokens.read }.reduce(0, +) == 80)
            #expect(records.map { $0.event.tokens.output }.reduce(0, +) == 20)
        }
    }

    @Test func inheritedChildPrefixEstablishesBaselineBeforeTheChildTurn() throws {
        var child = meta
        var payload = child["payload"] as! [String: Any]; payload["forked_from_id"] = "parent"
        child["payload"] = payload
        func legacy(_ input: Int) -> [String: Any] {
            [
                "type": "event_msg", "timestamp": stamp,
                "payload": [
                    "type": "token_count",
                    "info": ["total_token_usage": ["input_tokens": input, "output_tokens": 0]],
                ],
            ]
        }
        try snapshot([
            child, context, legacy(500),
            ["type": "event_msg", "payload": ["type": "task_started"]], legacy(520),
        ]) { records in
            #expect(records.count == 1); #expect(records[0].event.tokens.input == 20)
        }
    }

    @Test func recordedServiceTiersApplyChronologically() throws {
        let priority: [String: Any] = [
            "type": "event_msg",
            "payload": ["type": "thread_settings_applied", "service_tier": "priority"],
        ]
        let standard: [String: Any] = [
            "type": "event_msg",
            "payload": ["type": "thread_settings_applied", "service_tier": "default"],
        ]
        try snapshot([meta, context, priority, modern("fast"), standard, modern("normal")]) {
            records in
            #expect(records[0].event.serviceTier == "priority")
            #expect(records[1].event.serviceTier == "default")
            #expect(
                UsageNativePricing.estimate(records[0].event).cost == UsageNativePricing.estimate(
                    records[1].event
                ).cost * 2)
        }
    }

    @Test func anthropicWrappedReceiptsKeepSidechainIdentityAndObservedCost() throws {
        let row: [String: Any] = [
            "type": "assistant", "timestamp": stamp, "sessionId": "mock", "requestId": "request",
            "isSidechain": true,
            "cwd": "/mock/project/.claude/worktrees/review", "costUSD": 1.5,
            "message": [
                "id": "message", "model": "claude-opus-5-5",
                "usage": ["input_tokens": 10, "output_tokens": 2],
            ],
        ]
        let records = try UsageNativeParser(source: "cli").consume(["data": ["message": row]])
        let event = try #require(records.first?.event)
        #expect(event.identity == "message:request:true")
        #expect(event.cwd == "/mock/project/.claude/worktrees/review")
        #expect(UsageNativePricing.estimate(event).cost == 1.5)
        #expect(!UsageNativePricing.estimate(event).missing)
    }

    @Test func openCodeReasoningAndCacheCountersUseNativeShape() throws {
        let records = try UsageNativeParser(source: "opencode").consume([
            "role": "assistant", "id": "mock-message", "sessionID": "mock-session",
            "modelID": "mock-model", "time": ["created": 1_700_000_000_000],
            "path": ["cwd": "/mock/project"], "cost": 0.25,
            "tokens": [
                "input": 10, "output": 20, "reasoning": 3, "cache": ["read": 5, "write": 7],
            ],
        ])
        #expect(records.first?.event.tokens == .init(input: 10, output: 23, creation: 7, read: 5))
        #expect(records.first?.event.recordedCost == 0.25)
    }

    @Test func cursorCostsAreDollarsAndChatsHaveStableOpaqueReceiptIdentity() throws {
        let records = try UsageNativeParser(source: "cursor").consume([
            "timestamp": 1_700_000_000_000, "conversationId": "mock-conversation",
            "model": "mock-model", "chargedCents": 125,
            "tokenUsage": [
                "inputTokens": 10, "outputTokens": 2, "cacheWriteTokens": 3, "cacheReadTokens": 4,
            ],
        ])
        #expect(records.first?.event.recordedCost == 1.25)
        #expect(records.first?.event.tokens.total == 19)
        #expect(records.first?.event.session == "mock-conversation")
    }

    @Test func unknownPricingIsExplicitAndObservedCostWins() throws {
        let event = UsageNativeEvent(
            source: "mock", identity: "mock", session: "mock", model: "unknown-mock-model",
            timestamp: .now,
            cwd: "/mock/project", title: nil, tokens: .init(input: 10, output: 2), recordedCost: nil
        )
        #expect(UsageNativePricing.estimate(event).missing)
        var observed = event; observed.recordedCost = 4.5
        #expect(UsageNativePricing.estimate(observed).cost == 4.5)
        #expect(!UsageNativePricing.estimate(observed).missing)
        #expect(UsageNativePricingSnapshot.revision.count == 40)
    }

    @Test func longContextAndHourCacheRatesComeFromThePinnedDataset() {
        var event = UsageNativeEvent(
            source: "mock", identity: "mock", session: "mock", model: "gpt-6.1-sol",
            timestamp: .now,
            cwd: "", title: nil, tokens: .init(input: 300_000, output: 10), recordedCost: nil,
            serviceTier: "priority")
        #expect(
            abs(UsageNativePricing.estimate(event).cost - (300_000 * 0.000008 + 10 * 0.00003))
                < 0.0000001)
        event.model = "claude-opus-5-5"; event.serviceTier = nil
        event.tokens = .init(input: 0, output: 0, creation: 100, read: 0, creationHour: 60)
        #expect(
            abs(UsageNativePricing.estimate(event).cost - (40 * 0.000005 + 60 * 0.000008))
                < 0.0000001)
    }

    private var stamp: String { "2026-09-05T01:00:00Z" }
    private var meta: [String: Any] {
        ["type": "session_meta", "payload": ["id": "mock-thread", "cwd": "/mock/project"]]
    }
    private var context: [String: Any] {
        ["type": "turn_context", "payload": ["model": "gpt-6.1-sol"]]
    }
    private func modern(_ response: String, input: Int = 100, thread: String = "mock-thread")
        -> [String: Any]
    {
        [
            "type": "token_usage_record", "timestamp": stamp,
            "payload": [
                "thread_id": thread, "response_id": response,
                "usage": ["input_tokens": input, "output_tokens": 10],
            ],
        ]
    }
    private func snapshot(
        _ rows: [[String: Any]], assertion: ([UsageNativeParsedRecord]) throws -> Void
    ) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "usage-native-" + UUID().uuidString)
        try UsageNativeFileIO.privateDirectory(root)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("mock.jsonl")
        try rows.reduce(Data()) { try $0 + UsageNativeJSON.encode($1) + Data([10]) }.write(to: path)
        let snapshot = try UsageNativeParser(source: "codex").snapshot(
            path, key: "mock", previous: nil)
        try assertion(snapshot.records)
    }
}
