import Foundation
import Testing

@testable import EdithKit

struct AgentSearchFixture {
    static let now = Date(timeIntervalSince1970: 1_790_000_000)

    let home: URL
    let firstPID = Int32(ProcessInfo.processInfo.processIdentifier)
    let secondPID = Int32(getppid())

    init() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-search-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    var herdrScript: URL { home.appendingPathComponent("fake-herdr") }

    func engine(store: URL? = nil) -> AgentSessionSearch {
        let folder = home
        return AgentSessionSearch(
            environment: AgentSessionEnvironment(
                home: home,
                herdr: { arguments in
                    if arguments.contains("snapshot") {
                        return try? String(
                            contentsOf: folder.appendingPathComponent("snapshot.json"),
                            encoding: .utf8)
                    }
                    guard arguments.contains("read"), let pane = arguments.dropFirst(4).first
                    else { return nil }
                    return try? String(
                        contentsOf: folder.appendingPathComponent("pane-\(pane).txt"),
                        encoding: .utf8)
                },
                isAlive: { kill($0, 0) == 0 || errno == EPERM }),
            store: store)
    }

    @discardableResult
    func write(_ relative: String, _ lines: [[String: Any]]) throws -> URL {
        let url = home.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.encode(lines).write(to: url)
        return url
    }

    func writeText(_ relative: String, _ text: String) throws {
        let url = home.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
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

    static func target(
        _ pane: String, kind: String, cwd: String, title: String
    ) -> AgentSearchTarget {
        AgentSearchTarget(
            id: "local|default|\(pane)", kind: kind, session: "default", pane: pane, cwd: cwd,
            title: title)
    }

    static let targets = [
        target("p1", kind: "Claude Code", cwd: "/work/atlas", title: "✳ Speed up app launch"),
        target("p2", kind: "Claude Code", cwd: "/work/atlas/", title: "Rewrite onboarding docs"),
        target("p3", kind: "Codex", cwd: "/srv/billing", title: "codex"),
        target("p4", kind: "Pi", cwd: "/work/pics", title: "pi"),
        target("p5", kind: "OpenCode", cwd: "/work/shop", title: "opencode"),
        target("p6", kind: "Gemini", cwd: "/work/x", title: "gemini"),
    ]

    func seed() throws {
        var launch: [[String: Any]] = [
            ["type": "ai-title", "sessionId": "c-launch", "aiTitle": "Speed up app launch"],
            Self.claudeUser(
                "c-launch", "Profile the app launch and apply optimizations to startup",
                cwd: "/work/atlas", at: "2026-09-20T10:00:00.000Z"),
            Self.claudeUser(
                "c-launch", "Also wire the zebra telemetry counters into the launch trace",
                cwd: "/work/atlas", at: "2026-09-20T10:01:00.000Z"),
        ]
        for index in 0..<40 {
            launch.append(
                Self.claudeUser(
                    "c-launch", "Follow up step \(index) on font loading", cwd: "/work/atlas",
                    at: "2026-09-20T11:00:00.000Z"))
        }
        launch.append(
            Self.claudeReply(
                "c-launch", "Cut launch time by caching the font registry.",
                at: "2026-09-20T12:00:00.000Z"))
        try write(".claude/projects/-work-atlas/c-launch.jsonl", launch)
        try write(
            ".claude/projects/-work-atlas/c-docs.jsonl",
            [
                ["type": "ai-title", "sessionId": "c-docs", "aiTitle": "Rewrite onboarding docs"],
                Self.claudeUser(
                    "c-docs", "Rewrite the onboarding docs for the settings page",
                    cwd: "/work/atlas", at: "2026-09-22T09:00:00.000Z"),
            ])
        try write(
            ".claude/projects/-work-atlas/c-old.jsonl",
            [
                Self.claudeUser(
                    "c-old", "Plan the flamingo migration", cwd: "/work/atlas",
                    at: "2026-09-10T09:00:00.000Z")
            ])
        for (pid, session, started) in [
            (firstPID, "c-launch", 1_789_000_000_000.0), (secondPID, "c-docs", 1_789_100_000_000.0),
            (Int32(999_999), "c-old", 1_788_000_000_000.0),
        ] {
            let object: [String: Any] = [
                "pid": Int(pid), "sessionId": session, "cwd": "/work/atlas", "startedAt": started,
            ]
            try writeText(
                ".claude/sessions/\(pid).json",
                String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self))
        }
        try write(
            ".codex/sessions/2026/09/21/rollout-2026-09-21T08-00-00-codex-3.jsonl",
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
            ])
        try write(
            ".codex/session_index.jsonl",
            [["id": "codex-3", "thread_name": "Invoice rounding", "updated_at": "x"]])
        try write(
            ".pi/agent/sessions/--work-pics--/2026_pi-4.jsonl",
            [
                [
                    "type": "session", "id": "pi-4", "cwd": "/work/pics",
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
        try openCode()
        try writeText(
            "snapshot.json",
            #"{"id":"cli:snapshot","result":{"snapshot":{"agents":[{"pane_id":"p3","agent":"codex","agent_session":{"agent":"codex","kind":"id","source":"herdr:codex","value":"codex-3"}},{"pane_id":"p5","agent":"opencode","agent_session":{"agent":"opencode","kind":"id","source":"herdr:opencode","value":"ses_1"}}]}}}"#
        )
        try writeText(
            "pane-p6.txt", "gemini > deploy the staging pipeline\nDone: staging is green\n")
        try writeText(
            "fake-herdr",
            """
            #!/bin/sh
            folder=$(cd "$(dirname "$0")" && pwd)
            case "$*" in
              *"api snapshot"*) cat "$folder/snapshot.json" ;;
              *"pane read"*) cat "$folder/pane-$5.txt" 2>/dev/null || exit 1 ;;
              *) exit 1 ;;
            esac

            """)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: herdrScript.path)
    }

    func openCode() throws {
        let database = home.appendingPathComponent(".local/share/opencode/opencode.db")
        try FileManager.default.createDirectory(
            at: database.deletingLastPathComponent(), withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [
            database.path,
            """
            create table session_v2 (id text primary key, directory text not null, title text, time_updated integer);
            create table session_message (id text primary key, session_id text not null, type text not null, seq integer not null, time_created integer not null, data text not null);
            insert into session_v2 values ('ses_1', '/work/shop', 'Cart checkout', 1790000000000);
            insert into session_message values ('m1', 'ses_1', 'user', 1, 1789990000000, '{"text":"Make the cart checkout faster"}');
            insert into session_message values ('m2', 'ses_1', 'assistant', 2, 1789990100000, '{"content":[{"type":"text","text":"Batched the cart queries."}]}');
            """,
        ]
        try process.run()
        process.waitUntilExit()
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

    @Test func keepsWordsWithCombiningMarksWhole() {
        #expect(AgentSearchTerms.terms("किताब की दुकान") == ["किताब", "की", "दुकान"])
        #expect(AgentSearchTerms.terms("café résumé") == ["café", "résumé"])
    }

    @Test func dropsStopWordsAndSingleLetters() {
        #expect(
            AgentSearchTerms.terms("Make the app faster, please: a 2x win") == [
                "mak", "app", "fast", "2x", "win",
            ])
    }
}

@Suite struct AgentSessionSearchTests {
    @Test func everyOpenAgentGetsItsOwnHistory() async throws {
        let fixture = try AgentSearchFixture()
        try fixture.seed()
        let reply = await fixture.engine().search(
            AgentSearchRequest(query: "", targets: AgentSearchFixture.targets),
            now: AgentSearchFixture.now)
        #expect(reply.hits.map(\.id) == AgentSearchFixture.targets.map(\.id))
        #expect(
            reply.hits.map(\.sessionID) == ["c-launch", "c-docs", "codex-3", "pi-4", "ses_1", nil])
        #expect(
            reply.hits.map(\.source) == [
                .transcript, .transcript, .transcript, .transcript, .transcript, .terminal,
            ])
        #expect(reply.hits[2].title == "Invoice rounding")
        #expect(reply.hits[4].title == "Cart checkout")
        #expect(reply.hits[5].snippet == "Done: staging is green")
        #expect(reply.pending == 0)
    }

    @Test func searchReadsTheWholeHistoryOfOpenAgentsOnly() async throws {
        let fixture = try AgentSearchFixture()
        try fixture.seed()
        let engine = fixture.engine()
        let zebra = await engine.search(
            AgentSearchRequest(query: "zebra telemetry", targets: AgentSearchFixture.targets))
        #expect(zebra.hits.map(\.id) == ["local|default|p1"])
        #expect(zebra.hits.first?.snippet.contains("zebra telemetry") == true)
        let flamingo = await engine.search(
            AgentSearchRequest(query: "flamingo", targets: AgentSearchFixture.targets))
        #expect(flamingo.hits.isEmpty)
        let staging = await engine.search(
            AgentSearchRequest(query: "staging pipeline", targets: AgentSearchFixture.targets))
        #expect(staging.hits.first?.id == "local|default|p6")
        let cart = await engine.search(
            AgentSearchRequest(query: "cart checkout", targets: AgentSearchFixture.targets))
        #expect(cart.hits.first?.id == "local|default|p5")
    }

    @Test func herdrSessionLinksWinOverFolderGuesses() async throws {
        let fixture = try AgentSearchFixture()
        try fixture.seed()
        try fixture.writeText(
            "snapshot.json",
            #"{"result":{"snapshot":{"agents":[{"pane_id":"p1","agent_session":{"value":"c-old"}}]}}}"#
        )
        let reply = await fixture.engine().search(
            AgentSearchRequest(query: "", targets: Array(AgentSearchFixture.targets.prefix(2))))
        #expect(reply.hits.map(\.sessionID) == ["c-old", "c-docs"])
    }

    @Test func budgetReportsPendingAndTheNextSearchFinishes() async throws {
        let fixture = try AgentSearchFixture()
        try fixture.seed()
        var lines: [[String: Any]] = []
        let filler = String(repeating: "lorem ipsum ", count: 120)
        for index in 0..<8_000 {
            lines.append(
                AgentSearchFixture.claudeUser(
                    "c-launch", "prompt \(index) \(filler)", cwd: "/work/atlas",
                    at: "2026-09-20T10:00:00Z"))
        }
        try fixture.write(".claude/projects/-work-atlas/c-launch.jsonl", lines)
        try FileManager.default.removeItem(
            at: fixture.home.appendingPathComponent(".claude/sessions/\(fixture.secondPID).json"))
        let engine = fixture.engine()
        let targets = Array(AgentSearchFixture.targets.prefix(1))
        let first = await engine.search(AgentSearchRequest(query: "", targets: targets, budget: 0))
        #expect(first.pending == 1)
        let second = await engine.search(AgentSearchRequest(query: "", targets: targets))
        #expect(second.pending == 0)
        #expect(second.hits.first?.snippet.hasPrefix("prompt 7999 ") == true)
    }

    @Test func cachedHistoryResumesFromTheSavedOffset() async throws {
        let fixture = try AgentSearchFixture()
        try fixture.seed()
        let store = fixture.home.appendingPathComponent("store.json")
        let engine = fixture.engine(store: store)
        let targets = Array(AgentSearchFixture.targets.prefix(2))
        _ = await engine.search(AgentSearchRequest(query: "", targets: targets))
        await engine.flush()
        let reloaded = fixture.engine(store: store)
        let reply = await reloaded.search(
            AgentSearchRequest(query: "onboarding", targets: targets))
        #expect(reply.hits.map(\.sessionID) == ["c-docs"])
    }

    @Test func partialLastLineWaitsForItsNewline() throws {
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

    @Test func deadlineStopsBetweenChunksAndResumesFromTheOffset() throws {
        let fixture = try AgentSearchFixture()
        let filler = String(repeating: "lorem ipsum ", count: 40)
        var lines: [[String: Any]] = []
        for index in 0..<12_000 {
            lines.append(
                AgentSearchFixture.claudeUser(
                    "big", "prompt \(index) \(filler)", cwd: "/work", at: "2026-09-20T10:00:00Z"))
        }
        let url = try fixture.write(".claude/projects/-work/big.jsonl", lines)
        let size = try #require(
            try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64)
        #expect(size > UInt64(AgentTranscriptReader.chunkSize))
        var digest = AgentTranscriptDigest(path: url.path, kind: .claude)
        #expect(try !AgentTranscriptReader.update(&digest, url: url, deadline: .distantPast))
        #expect(digest.offset > 0 && digest.offset < size)
        #expect(try AgentTranscriptReader.update(&digest, url: url))
        #expect(digest.offset == size)
        #expect(digest.prompts.count == 12_000)
    }

    @Test func oversizedLinesAreSkippedWithoutLosingTheNextLine() throws {
        let fixture = try AgentSearchFixture()
        let url = try fixture.write(
            ".claude/projects/-work/wide.jsonl",
            [
                AgentSearchFixture.claudeUser(
                    "wide", String(repeating: "x", count: AgentTranscriptReader.lineLimit + 10),
                    cwd: "/work", at: "2026-09-20T10:00:00Z"),
                AgentSearchFixture.claudeUser(
                    "wide", "zebra migration plan", cwd: "/work", at: "2026-09-20T10:01:00Z"),
            ])
        var digest = AgentTranscriptDigest(path: url.path, kind: .claude)
        #expect(try AgentTranscriptReader.update(&digest, url: url))
        #expect(digest.prompts == ["zebra migration plan"])
    }
}

@Suite struct AgentSearchRemoteScriptTests {
    @Test func pythonScriptMatchesTheLocalEngine() async throws {
        let python = URL(fileURLWithPath: "/usr/bin/python3")
        guard FileManager.default.isExecutableFile(atPath: python.path),
            let script = AgentSearchRemote.scriptURL()
        else { return }
        let fixture = try AgentSearchFixture()
        try fixture.seed()
        for query in [
            "", "app optimizations", "zebra telemetry", "invoice rounding", "staging pipeline",
            "cart checkout", "flamingo", "atlas docs",
        ] {
            let request = AgentSearchRequest(
                query: query, machineID: "m1", targets: AgentSearchFixture.targets, budget: 30)
            let local = await fixture.engine().search(request, now: AgentSearchFixture.now)
            let process = Process()
            process.executableURL = python
            process.arguments = [script.path, try AgentSearchRemote.argument(for: request)]
            process.environment = [
                "EDITH_AGENT_SEARCH_HOME": fixture.home.path,
                "EDITH_AGENT_SEARCH_HERDR": fixture.herdrScript.path,
                "EDITH_AGENT_SEARCH_STORE": fixture.home.appendingPathComponent("py.json").path,
                "EDITH_AGENT_SEARCH_NOW": String(AgentSearchFixture.now.timeIntervalSince1970),
                "XDG_DATA_HOME": fixture.home.appendingPathComponent(".local/share").path,
            ]
            let output = Pipe()
            process.standardOutput = output
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let remote = try AgentSearchRemote.decode(data, machineID: "m1")
            #expect(remote.hits.map(\.id) == local.hits.map(\.id), "\(query)")
            #expect(remote.hits.map(\.sessionID) == local.hits.map(\.sessionID), "\(query)")
            #expect(remote.hits.map(\.source) == local.hits.map(\.source), "\(query)")
            #expect(remote.hits.map(\.title) == local.hits.map(\.title), "\(query)")
            #expect(remote.hits.map(\.snippet) == local.hits.map(\.snippet), "\(query)")
            for (left, right) in zip(remote.hits, local.hits) {
                #expect(abs(left.score - right.score) < 1e-6, "\(query) \(left.id)")
                #expect(left.lastActivity == right.lastActivity)
            }
        }
    }

    @Test func remoteCommandCarriesTheRequestAsBase64() throws {
        let request = AgentSearchRequest(
            query: "it's \"quoted\" $HOME", machineID: "m1",
            targets: [AgentSearchFixture.targets[0]])
        let command = try AgentSearchRemote.command(for: request)
        #expect(command.hasPrefix("python3 - "))
        let encoded = String(command.dropFirst("python3 - ".count))
        #expect(encoded.allSatisfy { $0.isLetter || $0.isNumber || "+/=".contains($0) })
        let decoded = try JSONDecoder().decode(
            AgentSearchRequest.self, from: try #require(Data(base64Encoded: encoded)))
        #expect(decoded == request)
    }
}

private actor AgentSearchServiceProbe {
    private(set) var queries: [String] = []
    private(set) var peak = 0
    private var active = 0
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func enter(_ query: String) {
        queries.append(query)
        active += 1
        peak = max(peak, active)
    }

    func leave() { active -= 1 }

    func hold() async {
        if released { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        released = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

@Suite struct AgentSearchServiceTests {
    @Test func remoteSearchesRunOneAtATimePerMachineAndSkipSupersededOnes() async throws {
        let fixture = try AgentSearchFixture()
        let machine = Machine(name: "devbox", host: "devbox.local")
        let probe = AgentSearchServiceProbe()
        let service = AgentSearchService(
            local: fixture.engine(), machines: { [machine] },
            remote: { request, _ in
                await probe.enter(request.query)
                if request.query == "first" { await probe.hold() }
                await probe.leave()
                return AgentSearchReply(machineID: request.machineID, hits: [])
            })
        let id = machine.id.uuidString
        func request(_ query: String) -> AgentSearchRequest {
            AgentSearchRequest(query: query, machineID: id, targets: [])
        }
        let first = Task { await service.search(request("first")) }
        for _ in 0..<200 where await probe.queries.isEmpty {
            try await Task.sleep(for: .milliseconds(5))
        }
        let second = Task { await service.search(request("second")) }
        try await Task.sleep(for: .milliseconds(50))
        let third = Task { await service.search(request("third")) }
        try await Task.sleep(for: .milliseconds(50))
        await probe.release()
        let replies = [await first.value, await second.value, await third.value]
        #expect(replies[0].error == nil)
        #expect(replies[1].error == AgentSearchService.superseded)
        #expect(replies[2].error == nil)
        #expect(await probe.queries == ["first", "third"])
        #expect(await probe.peak == 1)
    }

    @Test func unknownMachinesAnswerWithAnError() async throws {
        let fixture = try AgentSearchFixture()
        let service = AgentSearchService(local: fixture.engine(), machines: { [] })
        let reply = await service.search(
            AgentSearchRequest(query: "x", machineID: UUID().uuidString, targets: []))
        #expect(reply.error == "This machine is no longer in Edith.")
    }
}
