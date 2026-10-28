import Darwin
import Foundation
import Testing

@testable import UsageExtension

@Suite(.serialized) struct UsageNativeCapacityTests {
    private static let formerRecordCap = 2_000_000
    private static let formerFileCap = 100_000
    private static let formerFileBytes = 2_147_483_648

    @Test func historyAboveFormerArchiveCapsIndexesWithExactTotals() async throws {
        try await fixture { home, data in
            let journal = home.appendingPathComponent(".claude/projects/mock/session.jsonl")
            try write(claude(id: "live", input: 10, output: 2), journal)
            let seeded = Self.formerRecordCap + 100
            let archive = try UsageNativeArchive(dataDirectory: data)
            try archive.bootstrap(nil)
            let template = try UsageNativeParser(source: "cli").consume(
                UsageNativeJSON.object(claude(id: "template", input: 10, output: 2).dropLast())
            ).map(\.event)[0]
            let payload = String(decoding: try template.canonicalData, as: UTF8.self)
            try archive.database.transaction {
                try archive.database.run(
                    """
                    WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM n WHERE i<?)
                    INSERT INTO records(path,identity,hash,payload,source,ident,outtok,total)
                    SELECT 'bulk','id'||i,'h'||i,json_set(?,'$.identity','id'||i),'cli','id'||i,2,12 FROM n
                    """, [seeded, payload])
                try archive.database.run(
                    """
                    WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM n WHERE i<?)
                    INSERT INTO files(path,size,complete_bytes,mtime,hash,generation)
                    SELECT 'missing-'||i,1,1,1,'h',0 FROM n
                    """, [Self.formerFileCap + 1])
            }
            let issues = NoteBox()
            let document = try await collect(home, data, notes: issues)
            let totals = try #require(document["totals"] as? [String: Any])
            #expect(totals["tokens"] as? Double == Double(seeded + 1) * 12)
            #expect(issues.values.contains { $0.contains("missing journals") })
        }
    }

    @Test func journalLargerThanFormerByteCapIndexesAroundItsOversizedRegion() async throws {
        try await fixture { home, data in
            let journal = home.appendingPathComponent(".claude/projects/mock/session.jsonl")
            try FileManager.default.createDirectory(
                at: journal.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: journal.path, contents: nil)
            let handle = try FileHandle(forWritingTo: journal)
            try handle.write(contentsOf: claude(id: "head", input: 10, output: 2))
            try handle.seek(toOffset: UInt64(Self.formerFileBytes + 1_048_576))
            try handle.write(contentsOf: Data([10]))
            try handle.write(contentsOf: claude(id: "tail", input: 20, output: 4))
            try handle.close()
            let notes = NoteBox()
            let document = try await collect(home, data, notes: notes)
            let totals = try #require(document["totals"] as? [String: Any])
            #expect(totals["tokens"] as? Double == 36)
            #expect(notes.values.contains { $0.hasPrefix("Claude Code: skipped 1 line") })
        }
    }

    @Test func oversizedLineIsSkippedWithoutFailingTheCollection() async throws {
        try await fixture { home, data in
            let journal = home.appendingPathComponent(".claude/projects/mock/session.jsonl")
            var content = claude(id: "one", input: 10, output: 2)
            content += Data(repeating: 97, count: UsageNativeFileLimits().lineBytes + 1)
            content.append(10)
            content += claude(id: "two", input: 20, output: 4)
            content += Data(repeating: 98, count: UsageNativeFileLimits().lineBytes + 5)
            try write(content, journal)
            let notes = NoteBox()
            let document = try await collect(home, data, notes: notes)
            let totals = try #require(document["totals"] as? [String: Any])
            #expect(totals["tokens"] as? Double == 36)
            #expect(notes.values.contains { $0.hasPrefix("Claude Code: skipped 1 line") })
            var appended = content
            appended.append(10)
            appended += claude(id: "three", input: 30, output: 6)
            try write(appended, journal)
            let again = try await collect(home, data, notes: NoteBox())
            let grown = try #require(again["totals"] as? [String: Any])
            #expect(grown["tokens"] as? Double == 72)
        }
    }

    @Test func oneUnreadableJournalDoesNotBlankOtherSources() async throws {
        try await fixture { home, data in
            let good = home.appendingPathComponent(".claude/projects/mock/session.jsonl")
            try write(claude(id: "good", input: 10, output: 2), good)
            let codex = home.appendingPathComponent(".codex/sessions/broken.jsonl")
            try write(Data("{}\n".utf8), codex)
            #expect(chmod(codex.path, 0) == 0)
            defer { chmod(codex.path, 0o600) }
            let notes = NoteBox()
            let document = try await collect(home, data, notes: notes)
            let totals = try #require(document["totals"] as? [String: Any])
            #expect(totals["tokens"] as? Double == 12)
            #expect(
                notes.values.contains { $0.hasPrefix("Codex: skipped 1 source") && $0.contains("broken.jsonl") })
        }
    }

    @Test func cloudPayloadOverTheNetworkLimitSkipsOnlyThatSource() async throws {
        try await fixture { home, data in
            let journal = home.appendingPathComponent(".claude/projects/mock/session.jsonl")
            try write(claude(id: "local", input: 10, output: 2), journal)
            try write(
                try UsageNativeJSON.encode([
                    "claudeAiOauth": [
                        "accessToken": "mock-token", "scopes": ["user:sessions:claude_code"],
                    ]
                ]), home.appendingPathComponent(".claude/.credentials.json"))
            let notes = NoteBox()
            let network = UsageNativeNetwork(maximumBytes: 8) { _ in
                (Data(repeating: 65, count: 9), 200)
            }
            let document = try UsageNativeJSON.object(
                await UsageNativeCollector.collect(
                    home: home, dataDirectory: data, environment: ["TZ": "UTC"],
                    now: Date(timeIntervalSince1970: 1_788_566_400), network: network,
                    onEvent: { event in
                        if case .note(let text) = event { notes.append(text) }
                    }))
            let totals = try #require(document["totals"] as? [String: Any])
            #expect(totals["tokens"] as? Double == 12)
            #expect(notes.values.contains { $0.hasPrefix("Claude Code Web refresh is unavailable") })
        }
    }

    private func collect(_ home: URL, _ data: URL, notes: NoteBox) async throws -> [String: Any] {
        try UsageNativeJSON.object(
            await UsageNativeCollector.collect(
                home: home, dataDirectory: data,
                environment: ["EDITH_USAGE_OFFLINE": "1", "TZ": "UTC"],
                now: Date(timeIntervalSince1970: 1_788_566_400), network: UsageNativeNetwork(),
                onEvent: { event in
                    if case .note(let text) = event { notes.append(text) }
                }))
    }

    private func claude(id: String, input: Int, output: Int) -> Data {
        var data = try! UsageNativeJSON.encode([
            "timestamp": "2026-09-05T01:00:00Z", "sessionId": "mock-claude",
            "requestId": "request-" + id, "cwd": "/mock/project",
            "message": [
                "id": id, "model": "claude-sonnet-4-5",
                "usage": ["input_tokens": input, "output_tokens": output],
            ],
        ])
        data.append(10)
        return data
    }

    private func write(_ value: Data, _ path: URL) throws {
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try value.write(to: path)
    }

    private func fixture(_ action: (URL, URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "usage-native-capacity-" + UUID().uuidString)
        try UsageNativeFileIO.privateDirectory(root)
        defer { try? FileManager.default.removeItem(at: root) }
        try await action(root.appendingPathComponent("home"), root.appendingPathComponent("data"))
    }
}

private final class NoteBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    var values: [String] { lock.withLock { stored } }
    func append(_ value: String) { lock.withLock { stored.append(value) } }
}
