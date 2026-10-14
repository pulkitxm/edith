import Foundation
import Testing

@testable import UsageExtension

@MainActor @Suite(.serialized) struct UsageAccountSourceTests {
    private let video = UUID()
    private let removed = UUID()

    @Test func taggedClaudeSessionsBecomeAccountSourcesAndUntaggedStayPersonal() async throws {
        try await fixture { home, data in
            for (session, tokens) in [("personal", 10), ("video", 20), ("gone", 40)] {
                try write(
                    claude(session: session, tokens: tokens),
                    home.appendingPathComponent(".claude/projects/synthetic/\(session).jsonl"))
            }
            try write(
                claude(session: "video", tokens: 80, message: "video-subagent"),
                home.appendingPathComponent(
                    ".claude/projects/synthetic/video/subagents/agent-synthetic.jsonl"))
            let accounts = UsageNativeAccounts(
                sessions: ["video": video, "gone": removed], names: [video: "Video 20x"])
            let encoded = try await UsageNativeCollector.collect(
                home: home, dataDirectory: data,
                environment: ["EDITH_USAGE_OFFLINE": "1", "TZ": "UTC"],
                now: Date(timeIntervalSince1970: 1_788_566_400), network: .init(),
                accounts: accounts, onEvent: { _ in })
            #expect(UsageHistory.isValidDocument(encoded))
            let document = try UsageNativeJSON.object(encoded)
            let videoSource = "account:" + video.uuidString.lowercased() + ":cli"
            let removedSource = "account:" + removed.uuidString.lowercased() + ":cli"
            #expect(
                Set(document["sources"] as? [String] ?? []) == ["cli", videoSource, removedSource])
            let totals = try #require(document["totals"] as? [String: Any])
            let bySource = try #require(totals["bySource"] as? [String: [String: Any]])
            #expect(bySource["cli"]?["tokens"] as? Double == 12)
            #expect(bySource[videoSource]?["tokens"] as? Double == 104)
            #expect(bySource[removedSource]?["tokens"] as? Double == 42)
            let meta = try #require(document["sourceMeta"] as? [String: [String: String]])
            #expect(meta["cli"] == ["label": "Claude Code", "tool": "cli"])
            #expect(meta[videoSource] == ["label": "Claude Code · Video 20x", "tool": "cli"])
            #expect(meta[removedSource]?["label"] == "Claude Code · Removed account")
            let dashboard = DashboardModel(preferences: try preferences())
            dashboard.ingest(try JSONDecoder().decode(DashUsage.self, from: encoded))
            #expect(
                Set(dashboard.allSources.map(\.label)) == [
                    "Claude Code", "Claude Code · Video 20x", "Claude Code · Removed account",
                ])
        }
    }

    @Test func emptyAccountsLeaveEveryClaudeSessionPersonal() async throws {
        try await fixture { home, data in
            try write(
                claude(session: "video", tokens: 20),
                home.appendingPathComponent(".claude/projects/synthetic/video.jsonl"))
            let document = try UsageNativeJSON.object(
                await UsageNativeCollector.collect(
                    home: home, dataDirectory: data,
                    environment: ["EDITH_USAGE_OFFLINE": "1", "TZ": "UTC"],
                    now: Date(timeIntervalSince1970: 1_788_566_400), network: .init(),
                    onEvent: { _ in }))
            #expect(document["sources"] as? [String] == ["cli"])
        }
    }

    @Test func accountSourcesOnlyApplyToLocalClaudeCode() {
        let accounts = UsageNativeAccounts(sessions: ["shared": video], names: [video: "Video"])
        let event = { (source: String) in
            UsageNativeEvent(
                source: source, session: "shared", model: "synthetic", timestamp: Date(),
                cwd: "/synthetic", tokens: .init(input: 1))
        }
        #expect(accounts.source(of: event("codex")) == "codex")
        #expect(accounts.source(of: event("cowork")) == "cowork")
        #expect(
            accounts.source(of: event("cli")) == "account:" + video.uuidString.lowercased() + ":cli"
        )
        #expect(accounts.label("cli") == nil)
        #expect(accounts.label("machine:" + video.uuidString.lowercased() + ":cli") == nil)
    }

    private func claude(session: String, tokens: Int, message: String? = nil) throws -> Data {
        var data = try UsageNativeJSON.encode([
            "timestamp": "2026-09-05T01:00:00Z", "sessionId": session,
            "requestId": "request-" + (message ?? session), "cwd": "/synthetic/project",
            "costUSD": 1,
            "message": [
                "id": message ?? session, "model": "claude-sonnet-4-5",
                "usage": ["input_tokens": tokens, "output_tokens": 2],
            ],
        ])
        data.append(10)
        return data
    }

    private func preferences() throws -> UserDefaults {
        let suite = "UsageAccountSourceTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func fixture(_ action: (URL, URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "usage-account-source-" + UUID().uuidString)
        try UsageNativeFileIO.privateDirectory(root)
        defer { try? FileManager.default.removeItem(at: root) }
        try await action(root.appendingPathComponent("home"), root.appendingPathComponent("data"))
    }

    private func write(_ value: Data, _ path: URL) throws {
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try value.write(to: path)
    }
}
