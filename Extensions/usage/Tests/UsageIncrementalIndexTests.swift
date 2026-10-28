import Foundation
import Testing

@testable import UsageExtension

@Suite(.serialized) struct UsageIncrementalIndexTests {
    @Test func appendParsesOnlyNewBytesAndTotalsMatchAFullParse() throws {
        try fixture { root in
            let path = root.appendingPathComponent("journal.jsonl")
            let archive = try UsageNativeArchive(dataDirectory: root)
            try archive.bootstrap(nil)
            let first = (0..<40).map { claude(id: "a\($0)", input: $0 + 1) }.reduce(Data(), +)
            try first.write(to: path)
            let initial = try admit(path, archive: archive)
            #expect(initial.records.count == 40)

            let more = (0..<5).map { claude(id: "b\($0)", input: 100 + $0) }.reduce(Data(), +)
            try append(more, to: path)
            let update = try admit(path, archive: archive)
            #expect(update.records.count == 5)
            #expect(update.records.map(\.offset).min() == first.count)
            #expect(update.appended == true)

            let reference = try UsageNativeArchive(
                dataDirectory: root.appendingPathComponent("reference"))
            try reference.bootstrap(nil)
            _ = try admit(path, archive: reference)
            #expect(try total(archive) == total(reference))
            #expect(try archive.events().count == 45)
        }
    }

    @Test func untouchedAppendOfNothingParsesNothing() throws {
        try fixture { root in
            let path = root.appendingPathComponent("journal.jsonl")
            let archive = try UsageNativeArchive(dataDirectory: root)
            try archive.bootstrap(nil)
            try claude(id: "a", input: 3).write(to: path)
            _ = try admit(path, archive: archive)
            let again = try admit(path, archive: archive)
            #expect(again.records.isEmpty)
        }
    }

    @Test func truncationAndRewriteTriggerAFullReparse() throws {
        try fixture { root in
            let path = root.appendingPathComponent("journal.jsonl")
            let archive = try UsageNativeArchive(dataDirectory: root)
            try archive.bootstrap(nil)
            let rows = (0..<30).map { claude(id: "a\($0)", input: 7) }.reduce(Data(), +)
            try rows.write(to: path)
            _ = try admit(path, archive: archive)

            let shorter = (0..<3).map { claude(id: "c\($0)", input: 9) }.reduce(Data(), +)
            try shorter.write(to: path)
            let truncated = try admit(path, archive: archive)
            #expect(truncated.appended == false)
            #expect(truncated.records.map(\.offset).min() == 0)
            #expect(truncated.records.count == 3)

            let sameLengthDifferentHead = Data(
                String(decoding: shorter, as: UTF8.self).replacingOccurrences(
                    of: "\"c0\"", with: "\"d0\""
                ).utf8)
            try sameLengthDifferentHead.write(to: path)
            let rewritten = try admit(path, archive: archive)
            #expect(rewritten.appended == false)
            #expect(rewritten.records.count == 3)
        }
    }

    @Test func codexRunningTotalsContinueAcrossAppendsLikeAFullParse() throws {
        try fixture { root in
            let path = root.appendingPathComponent("session.jsonl")
            let archive = try UsageNativeArchive(dataDirectory: root)
            try archive.bootstrap(nil)
            try (codexMeta() + codexTotal(100, at: 0) + codexTotal(250, at: 1)).write(to: path)
            _ = try admit(path, archive: archive, source: "codex")
            try append(codexTotal(400, at: 2) + codexTotal(700, at: 3), to: path)
            let update = try admit(path, archive: archive, source: "codex")
            #expect(update.records.count == 2)

            let reference = try UsageNativeArchive(
                dataDirectory: root.appendingPathComponent("reference"))
            try reference.bootstrap(nil)
            _ = try admit(path, archive: reference, source: "codex")
            #expect(try total(archive) == total(reference))
            #expect(try total(archive) == 700)
        }
    }

    @Test func legacyRowsWithoutStateStillAppendWithoutDoubleCounting() throws {
        try fixture { root in
            let path = root.appendingPathComponent("journal.jsonl")
            let archive = try UsageNativeArchive(dataDirectory: root)
            try archive.bootstrap(nil)
            try (0..<4).map { claude(id: "a\($0)", input: 5) }.reduce(Data(), +).write(to: path)
            _ = try admit(path, archive: archive)
            try archive.database.run("UPDATE files SET state=NULL")
            try append(claude(id: "z", input: 5), to: path)
            let update = try admit(path, archive: archive)
            #expect(update.records.count == 5)
            #expect(try archive.events().count == 5)
        }
    }

    private func admit(_ path: URL, archive: UsageNativeArchive, source: String = "cli") throws
        -> UsageNativeFileSnapshot
    {
        let key = "journal"
        let previous = try archive.known(key)
        let snapshot = try UsageNativeParser(source: source).snapshot(
            path, key: key, previous: previous)
        try archive.admit(snapshot, previous: previous)
        return snapshot
    }

    private func total(_ archive: UsageNativeArchive) throws -> Double {
        try archive.events().reduce(0) { $0 + $1.tokens.total }
    }

    private func append(_ data: Data, to path: URL) throws {
        let handle = try FileHandle(forWritingTo: path)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    private func claude(id: String, input: Int) -> Data {
        let message: [String: Any] = [
            "id": id, "model": "mock-model",
            "usage": ["input_tokens": input, "output_tokens": 2],
        ]
        return
            (try! UsageNativeJSON.encode([
                "timestamp": "2026-09-05T01:00:00Z", "sessionId": "mock-session",
                "requestId": "r-" + id, "message": message,
            ])) + Data([10])
    }

    private func codexMeta() throws -> Data {
        try UsageNativeJSON.encode(["type": "session_meta", "payload": ["id": "mock-codex"]])
            + Data([10])
    }

    private func codexTotal(_ total: Int, at index: Int) throws -> Data {
        try UsageNativeJSON.encode([
            "type": "event_msg", "timestamp": "2026-09-05T02:0\(index):00Z",
            "payload": [
                "type": "token_count",
                "info": ["total_token_usage": ["input_tokens": total - 10, "output_tokens": 10]],
            ],
        ]) + Data([10])
    }

    private func fixture(_ action: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "usage-incremental-" + UUID().uuidString)
        try UsageNativeFileIO.privateDirectory(root)
        defer { try? FileManager.default.removeItem(at: root) }
        try action(root)
    }
}
