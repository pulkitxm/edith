import Foundation
import Testing

@testable import EdithKit

struct AgentSearchFixture {
    let home: URL

    init() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-search-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    var roots: AgentTranscriptRoots { .home(home) }

    func index(store: URL? = nil) -> AgentTranscriptIndex {
        AgentTranscriptIndex(roots: roots, store: store)
    }

    @discardableResult
    func write(_ relative: String, _ lines: [[String: Any]]) throws -> URL {
        let url = home.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.encode(lines).write(to: url)
        return url
    }

    func append(_ relative: String, _ lines: [[String: Any]]) throws {
        let handle = try FileHandle(forWritingTo: home.appendingPathComponent(relative))
        try handle.seekToEnd()
        try handle.write(contentsOf: Self.encode(lines))
        try handle.close()
    }

    static func encode(_ lines: [[String: Any]]) throws -> Data {
        var data = Data()
        for line in lines {
            data.append(try JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]))
            data.append(0x0A)
        }
        return data
    }

    static func claudeUser(_ session: String, _ text: String, cwd: String, at stamp: String)
        -> [String: Any]
    {
        [
            "type": "user", "sessionId": session, "cwd": cwd, "gitBranch": "main",
            "timestamp": stamp, "message": ["role": "user", "content": text],
        ]
    }

    static func claudeReply(_ session: String, _ text: String, at stamp: String) -> [String: Any] {
        [
            "type": "assistant", "sessionId": session, "timestamp": stamp,
            "message": ["role": "assistant", "content": [["type": "text", "text": text]]],
        ]
    }

    func seed() throws {
        try write(
            ".claude/projects/-work-atlas/perf-1.jsonl",
            [
                Self.claudeUser(
                    "perf-1", "Profile the app launch and apply optimizations to startup",
                    cwd: "/work/atlas", at: "2026-09-20T10:00:00.000Z"),
                Self.claudeReply(
                    "perf-1", "Cut launch time by caching the font registry.",
                    at: "2026-09-20T10:05:00.000Z"),
                ["type": "ai-title", "sessionId": "perf-1", "aiTitle": "Speed up app launch"],
                [
                    "type": "user", "sessionId": "perf-1", "cwd": "/work/atlas",
                    "timestamp": "2026-09-20T10:06:00.000Z",
                    "message": [
                        "role": "user",
                        "content": [["type": "tool_result", "content": "optimizations noise"]],
                    ],
                ],
            ])
        try write(
            ".claude/projects/-work-atlas/docs-2.jsonl",
            [
                Self.claudeUser(
                    "docs-2", "Rewrite the onboarding docs for the settings page",
                    cwd: "/work/atlas", at: "2026-09-22T09:00:00.000Z"),
                [
                    "type": "user", "sessionId": "docs-2", "cwd": "/work/atlas", "isMeta": true,
                    "timestamp": "2026-09-22T09:01:00.000Z",
                    "message": ["role": "user", "content": "app optimizations meta noise"],
                ],
            ])
        try write(
            ".claude/projects/-work-atlas/docs-2/subagents/agent-a.jsonl",
            [
                Self.claudeUser(
                    "sub", "app optimizations inside a subagent", cwd: "/work/atlas",
                    at: "2026-09-22T09:02:00.000Z")
            ])
        try write(
            ".codex/sessions/2026/09/21/rollout-codex-3.jsonl",
            [
                [
                    "type": "session_meta", "timestamp": "2026-09-21T08:00:00.000Z",
                    "payload": ["id": "codex-3", "cwd": "/srv/billing"],
                ],
                [
                    "type": "response_item", "timestamp": "2026-09-21T08:00:01.000Z",
                    "payload": [
                        "type": "message", "role": "user",
                        "content": [
                            [
                                "type": "input_text",
                                "text": "<environment_context>x</environment_context>",
                            ]
                        ],
                    ],
                ],
                [
                    "type": "event_msg", "timestamp": "2026-09-21T08:00:02.000Z",
                    "payload": [
                        "type": "user_message",
                        "message": "Fix the invoice rounding bug in the billing export",
                    ],
                ],
                [
                    "type": "event_msg", "timestamp": "2026-09-21T08:10:00.000Z",
                    "payload": [
                        "type": "agent_message", "message": "Rounded half-even in the exporter.",
                    ],
                ],
            ])
        try write(
            ".codex/session_index.jsonl",
            [["id": "codex-3", "thread_name": "Invoice rounding", "updated_at": "x"]])
        try write(
            ".pi/agent/sessions/--work-atlas--/pi-4.jsonl",
            [
                [
                    "type": "session", "id": "pi-4", "cwd": "/work/atlas",
                    "timestamp": "2026-09-23T12:00:00.000Z",
                ],
                [
                    "type": "message", "timestamp": "2026-09-23T12:00:01.000Z",
                    "message": [
                        "role": "user",
                        "content": [["type": "text", "text": "Optimize the image pipeline"]],
                    ],
                ],
            ])
    }
}

@Suite struct AgentSearchTermsTests {
    @Test func stemsMorphologicalVariantsTogether() {
        for group in [
            ["optimizations", "optimization", "optimize", "optimized", "optimizing"],
            ["caches", "cache"], ["queries", "query"], ["sessions", "session"],
            ["users", "user"], ["performance", "performing", "perform"],
        ] {
            #expect(Set(group.map(AgentSearchTerms.stem)).count == 1, "\(group)")
        }
        #expect(AgentSearchTerms.stem("apply") == "apply")
        #expect(AgentSearchTerms.stem("quickly") == "quick")
        #expect(!AgentSearchTerms.matches("apply", any: ["app"]))
        #expect(AgentSearchTerms.matches("optimizing", any: ["optim"]))
        #expect(AgentSearchTerms.matches("optimizations", any: AgentSearchTerms.terms("optimizer")))
        #expect(AgentSearchTerms.stem("status") == "status")
        #expect(AgentSearchTerms.stem("process") == "process")
        #expect(AgentSearchTerms.stem("v2") == "v2")
    }

    @Test func dropsStopWordsAndSingleLetters() {
        #expect(
            AgentSearchTerms.terms("Make the app faster, please: a 2x win") == [
                "mak", "app", "fast", "2x", "win",
            ])
    }
}

@Suite struct AgentTranscriptIndexTests {
    @Test func ranksTheMatchingSessionFirstAcrossAgentKinds() async throws {
        let fixture = try AgentSearchFixture()
        try fixture.seed()
        let reply = await fixture.index().search(
            AgentSearchRequest(query: "app optimizations", machineID: "local", limit: 5),
            now: Date(timeIntervalSince1970: 1_790_000_000))
        #expect(reply.hits.first?.sessionID == "perf-1")
        #expect(reply.hits.first?.title == "Speed up app launch")
        #expect(reply.hits.first?.kind == .claude)
        #expect(reply.hits.first?.snippet.contains("optimizations") == true)
        #expect(reply.hits.map(\.sessionID).contains("pi-4"))
        #expect(!reply.hits.map(\.sessionID).contains("sub"))
        #expect(!reply.hits.map(\.sessionID).contains("docs-2"))
        #expect(reply.indexed == 4)
        #expect(reply.pending == 0)
        #expect(reply.hits.allSatisfy { $0.id.hasPrefix("local|") })
    }

    @Test func readsCodexTitlesPromptsAndSkipsInjectedContext() async throws {
        let fixture = try AgentSearchFixture()
        try fixture.seed()
        let reply = await fixture.index().search(
            AgentSearchRequest(query: "invoice rounding", limit: 3))
        let hit = try #require(reply.hits.first)
        #expect(hit.sessionID == "codex-3")
        #expect(hit.kind == .codex)
        #expect(hit.title == "Invoice rounding")
        #expect(hit.cwd == "/srv/billing")
        #expect(hit.summary == "Fix the invoice rounding bug in the billing export")
    }

    @Test func emptyQueryListsRecentSessionsWithPlaceRanks() async throws {
        let fixture = try AgentSearchFixture()
        try fixture.seed()
        let reply = await fixture.index().search(AgentSearchRequest(query: "  ", limit: 10))
        #expect(reply.hits.map(\.sessionID) == ["pi-4", "docs-2", "codex-3", "perf-1"])
        let ranks = Dictionary(
            uniqueKeysWithValues: reply.hits.map { ($0.sessionID, $0.placeRank) })
        #expect(ranks["docs-2"] == 0)
        #expect(ranks["perf-1"] == 1)
        #expect(ranks["pi-4"] == 0)
    }

    @Test func appendedLinesAreReadFromTheSavedOffset() async throws {
        let fixture = try AgentSearchFixture()
        try fixture.seed()
        let store = fixture.home.appendingPathComponent("store.json")
        let index = fixture.index(store: store)
        #expect(await index.search(AgentSearchRequest(query: "telemetry dashboard")).hits.isEmpty)
        try fixture.append(
            ".claude/projects/-work-atlas/docs-2.jsonl",
            [
                AgentSearchFixture.claudeUser(
                    "docs-2", "Now add a telemetry dashboard", cwd: "/work/atlas",
                    at: "2026-09-24T09:00:00.000Z")
            ])
        let reply = await index.search(AgentSearchRequest(query: "telemetry dashboard"))
        #expect(reply.hits.first?.sessionID == "docs-2")
        #expect(reply.hits.first?.title == "Rewrite the onboarding docs for the settings page")
        await index.flush()
        let reloaded = fixture.index(store: store)
        let again = await reloaded.search(AgentSearchRequest(query: "telemetry dashboard"))
        #expect(again.hits.first?.sessionID == "docs-2")
    }

    @Test func partialLastLineWaitsForItsNewline() async throws {
        let fixture = try AgentSearchFixture()
        let url = try fixture.write(
            ".claude/projects/-work/half.jsonl",
            [
                AgentSearchFixture.claudeUser(
                    "half", "first prompt about graphs", cwd: "/work", at: "2026-09-20T10:00:00Z")
            ])
        let partial = try JSONSerialization.data(
            withJSONObject: AgentSearchFixture.claudeUser(
                "half", "second prompt about kernels", cwd: "/work", at: "2026-09-20T10:01:00Z"))
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: partial.prefix(40))
        try handle.close()
        var digest = AgentTranscriptDigest(path: url.path, kind: .claude)
        try AgentTranscriptReader.update(&digest, url: url)
        #expect(digest.prompts == ["first prompt about graphs"])
        let size = try #require(
            try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64)
        #expect(digest.offset < size)
        #expect(digest.lastActivity == 1_789_898_400)
    }

    @Test func timeBudgetIndexesNewestFilesFirstAndReportsPending() async throws {
        let fixture = try AgentSearchFixture()
        try fixture.seed()
        let reply = await fixture.index().search(
            AgentSearchRequest(query: "optimize", limit: 5, budget: 0))
        #expect(reply.indexed == 1)
        #expect(reply.pending == 3)
        #expect(reply.hits.map(\.sessionID) == ["pi-4"])
    }

    @Test func promptsKeepTheOpeningAndTheLatest() {
        var digest = AgentTranscriptDigest(path: "/x", kind: .claude)
        for index in 0..<40 {
            digest.addPrompt("prompt \(index) " + String(repeating: "word ", count: 60))
        }
        #expect(digest.prompts.first?.hasPrefix("prompt 0 ") == true)
        #expect(digest.prompts.last?.hasPrefix("prompt 39 ") == true)
        #expect(digest.prompts.reduce(0) { $0 + $1.count } <= AgentTranscriptDigest.promptsLimit)
    }
}

@Suite struct AgentSearchRemoteScriptTests {
    @Test func pythonScriptMatchesTheLocalIndex() async throws {
        let python = URL(fileURLWithPath: "/usr/bin/python3")
        guard FileManager.default.isExecutableFile(atPath: python.path),
            let script = AgentSearchRemote.scriptURL()
        else { return }
        let fixture = try AgentSearchFixture()
        try fixture.seed()
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        for query in ["app optimizations", "invoice rounding", "optimize", "", "atlas docs"] {
            let request = AgentSearchRequest(query: query, machineID: "m1", limit: 5, budget: 30)
            let local = await fixture.index().search(request, now: now)
            let process = Process()
            process.executableURL = python
            process.arguments = [script.path, try AgentSearchRemote.argument(for: request)]
            process.environment = [
                "EDITH_AGENT_SEARCH_HOME": fixture.home.path,
                "EDITH_AGENT_SEARCH_STORE": fixture.home.appendingPathComponent("py.json").path,
                "EDITH_AGENT_SEARCH_NOW": String(now.timeIntervalSince1970),
            ]
            let output = Pipe()
            process.standardOutput = output
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let remote = try AgentSearchRemote.decode(data, machineID: "m1")
            #expect(remote.hits.map(\.id) == local.hits.map(\.id), "\(query)")
            #expect(remote.hits.map(\.title) == local.hits.map(\.title), "\(query)")
            #expect(remote.hits.map(\.placeRank) == local.hits.map(\.placeRank), "\(query)")
            #expect(remote.indexed == local.indexed)
            for (left, right) in zip(remote.hits, local.hits) {
                #expect(abs(left.score - right.score) < 1e-6, "\(query) \(left.sessionID)")
                #expect(left.lastActivity == right.lastActivity)
            }
        }
    }

    @Test func remoteCommandCarriesTheRequestAsBase64() throws {
        let request = AgentSearchRequest(query: "it's \"quoted\" $HOME", machineID: "m1")
        let command = try AgentSearchRemote.command(for: request)
        #expect(command.hasPrefix("python3 - "))
        let encoded = String(command.dropFirst("python3 - ".count))
        #expect(encoded.allSatisfy { $0.isLetter || $0.isNumber || "+/=".contains($0) })
        let decoded = try JSONDecoder().decode(
            AgentSearchRequest.self, from: try #require(Data(base64Encoded: encoded)))
        #expect(decoded == request)
    }
}
