import Foundation
import Testing
@testable import UsageExtension

@Suite(.serialized) struct UsageNativeCloudTests {
    @Test func cloudSessionReceiptsCacheByRevisionAndExcludeLocalDuplicates() async throws {
        try await fixture { home, data in
            try credentials(home, token: "mock-cloud-token")
            let counter = RequestCounter()
            let network = UsageNativeNetwork { request in
                await counter.add(request.url!.path)
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer mock-cloud-token")
                #expect(request.url?.host == "api.anthropic.com")
                if request.url!.path.hasSuffix("teleport-events") {
                    return (try self.json(["data": [["payload": self.receipt(id: "same")], ["payload": self.receipt(id: "cloud-only")]]]), 200)
                }
                return (try self.json(["data": [["id": "mock-cloud-session", "last_event_at": "revision-one"]]]), 200)
            }
            let archive = try UsageNativeArchive(dataDirectory: data)
            let collected = try await UsageNativeCloud.collect(home: home, environment: [:], now: Date(), archive: archive, network: network, onEvent: { _ in })
            #expect(collected == ["claude-cloud"])
            #expect(await counter.count == 2)
            let cached = try await UsageNativeCloud.collect(home: home, environment: [:], now: Date(), archive: archive, network: network, onEvent: { _ in })
            #expect(cached == ["claude-cloud"])
            #expect(await counter.count == 3)
            let local = try UsageNativeParser(source: "cli").consume(receipt(id: "same")).map(\.event)
            let unique = UsageNativeAssembly.deduplicate(try archive.events() + local)
            #expect(unique.count == 2)
            #expect(unique.filter { $0.source == "claude-cloud" }.count == 1)
            let stored = try archive.database.rows("SELECT payload FROM cloud_cache").map { $0["payload"] ?? "" }.joined()
            #expect(!stored.contains("PRIVATE_CONTENT_CANARY"))
            #expect(!stored.contains("mock-cloud-token"))
        }
    }

    @Test func savedCloudReceiptsRemainAvailableDuringOutageButNotForDifferentCredentials() async throws {
        try await fixture { home, data in
            try credentials(home, token: "account-one")
            let archive = try UsageNativeArchive(dataDirectory: data)
            let online = UsageNativeNetwork { request in
                if request.url!.path.hasSuffix("teleport-events") {
                    return (try self.json(["data": [["payload": self.receipt(id: "cloud-only")]]]), 200)
                }
                return (try self.json(["data": [["id": "mock-session", "last_event_at": "one"]]]), 200)
            }
            _ = try await UsageNativeCloud.collect(home: home, environment: [:], now: Date(), archive: archive, network: online, onEvent: { _ in })
            let offline = UsageNativeNetwork { _ in throw URLError(.notConnectedToInternet) }
            #expect(try await UsageNativeCloud.collect(home: home, environment: [:], now: Date(), archive: archive, network: offline, onEvent: { _ in }) == ["claude-cloud"])
            try credentials(home, token: "account-two")
            #expect(try await UsageNativeCloud.collect(home: home, environment: [:], now: Date(), archive: archive, network: offline, onEvent: { _ in }).isEmpty)
        }
    }

    @Test func repeatedCloudPaginationCursorIsRejectedBeforeReceiptAdmission() async throws {
        try await fixture { home, data in
            try credentials(home, token: "mock-token")
            let archive = try UsageNativeArchive(dataDirectory: data)
            let network = UsageNativeNetwork { _ in (try self.json(["data": [], "next_cursor": "repeated"]), 200) }
            let sources = try await UsageNativeCloud.collect(home: home, environment: [:], now: Date(), archive: archive, network: network, onEvent: { _ in })
            #expect(sources.isEmpty)
            #expect(try archive.events().isEmpty)
        }
    }

    @Test func codexAnalyticsPaginateMonthWindowsAndReplaceCorrectedAmounts() async throws {
        try await fixture { home, data in
            try write(try json(["tokens": ["access_token": "mock-codex-token", "account_id": "mock-account"]]), home.appendingPathComponent(".codex/auth.json"))
            let archive = try UsageNativeArchive(dataDirectory: data)
            let dates = DateIntervals()
            let network = UsageNativeNetwork { request in
                let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
                let start = query.first { $0.name == "start_date" }!.value!
                let end = query.first { $0.name == "end_date" }!.value!
                await dates.add(start, end)
                #expect(request.value(forHTTPHeaderField: "ChatGPT-Account-Id") == "mock-account")
                return (try self.json(["group_by": "day", "balance_unit": "credit", "data": [["date": start, "clients": [["client_id": "CODEX_WEB", "uncached_text_input_tokens": 2, "cached_text_input_tokens": 1, "text_output_tokens": 1, "text_total_tokens": 4, "credits": 1]]]]]), 200)
            }
            let now = UsageNativeJSON.date("2025-06-15T20:00:00Z")!
            #expect(try await UsageNativeCloud.collect(home: home, environment: [:], now: now, archive: archive, network: network, onEvent: { _ in }) == ["codex-cloud"])
            #expect(await dates.intervals == [["2025-05-16", "2025-06-14"], ["2025-06-15", "2025-06-15"]])
            #expect(try archive.events().count == 2)
            let corrected = UsageNativeNetwork { request in
                let start = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "start_date" }!.value!
                return (try self.json(["group_by": "day", "data": [["date": start, "clients": [["client_id": "CODEX_WEB", "uncached_text_input_tokens": 2, "cached_text_input_tokens": 1, "text_output_tokens": 1, "text_total_tokens": 4, "cost_usd": 0.01]]]]]), 200)
            }
            _ = try await UsageNativeCloud.collect(home: home, environment: [:], now: now, archive: archive, network: corrected, onEvent: { _ in })
            #expect(try archive.events().count == 2)
            #expect(try archive.events().allSatisfy { $0.recordedCost == 0.01 })
        }
    }

    @Test func cursorUsageJoinsLocalMetadataAndReplacesItsApiSnapshot() async throws {
        try await fixture { home, data in
            try write(try json(["accessToken": "mock-cursor-token"]), home.appendingPathComponent(".cursor/auth.json"))
            try write(try json(["cwd": "/mock/project", "title": "Mock chat"]), home.appendingPathComponent(".cursor/chats/project/conversation/meta.json"))
            let archive = try UsageNativeArchive(dataDirectory: data)
            let network = UsageNativeNetwork { request in
                #expect(request.httpMethod == "POST")
                #expect(request.value(forHTTPHeaderField: "Connect-Protocol-Version") == "1")
                return (try self.json(["totalUsageEventsCount": 1, "usageEventsDisplay": [["timestamp": "2026-09-05T04:00:00Z", "model": "gpt-5", "conversationId": "conversation", "tokenUsage": ["inputTokens": 5, "outputTokens": 2], "chargedCents": "25"]]]), 200)
            }
            #expect(try await UsageNativeCloud.collect(home: home, environment: [:], now: Date(), archive: archive, network: network, onEvent: { _ in }) == ["cursor"])
            let receipt = try #require(try archive.events().first)
            #expect(receipt.cwd == "/mock/project")
            #expect(receipt.title == "Mock chat")
            #expect(receipt.recordedCost == 0.25)
            _ = try await UsageNativeCloud.collect(home: home, environment: [:], now: Date(), archive: archive, network: network, onEvent: { _ in })
            #expect(try archive.events().count == 1)
        }
    }

    @Test func cloudCancellationPropagatesAndDoesNotFallbackToCache() async throws {
        try await fixture { home, data in
            try credentials(home, token: "mock-token")
            let task = Task {
                let archive = try UsageNativeArchive(dataDirectory: data)
                let network = UsageNativeNetwork { _ in
                    try await Task.sleep(for: .seconds(30))
                    return (Data("{}".utf8), 200)
                }
                return try await UsageNativeCloud.collect(home: home, environment: [:], now: Date(), archive: archive, network: network, onEvent: { _ in })
            }
            try await Task.sleep(for: .milliseconds(50))
            let start = ContinuousClock.now
            task.cancel()
            do { _ = try await task.value; Issue.record("Cancelled refresh completed") }
            catch is CancellationError {}
            #expect(start.duration(to: .now) < .seconds(2))
        }
    }

    private func receipt(id: String) -> [String: Any] {
        ["type": "assistant", "timestamp": "2026-09-05T01:00:00Z", "sessionId": "mock-session", "requestId": "mock-request",
            "message": ["id": id, "model": "claude-sonnet-4-5", "usage": ["input_tokens": 10, "output_tokens": 2], "content": "PRIVATE_CONTENT_CANARY"]]
    }
    private func credentials(_ home: URL, token: String) throws {
        try write(try json(["claudeAiOauth": ["accessToken": token, "scopes": ["user:sessions:claude_code"]]]), home.appendingPathComponent(".claude/.credentials.json"))
    }
    private func json(_ value: Any) throws -> Data { try UsageNativeJSON.encode(value) }
    private func write(_ value: Data, _ path: URL) throws {
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try value.write(to: path)
    }
    private func fixture(_ action: (URL, URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("usage-native-cloud-" + UUID().uuidString)
        try UsageNativeFileIO.privateDirectory(root)
        defer { try? FileManager.default.removeItem(at: root) }
        try await action(root.appendingPathComponent("home"), root.appendingPathComponent("data"))
    }
}

private actor RequestCounter {
    private(set) var count = 0
    func add(_ path: String) { count += 1 }
}

private actor DateIntervals {
    private(set) var intervals: [[String]] = []
    func add(_ start: String, _ end: String) { intervals.append([start, end]) }
}
