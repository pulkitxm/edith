import Foundation
import Testing
@testable import EdithKit

@Suite struct LimitsHistoryTests {
    let now = Date(timeIntervalSince1970: 1_750_000_000)

    @Test func rowIsOneJSONLineAndKeyIgnoresTimestamp() throws {
        let s = LimitWindow(percent: 42.14, resetsAt: now.addingTimeInterval(3600))
        let w = LimitWindow(percent: 67.3, resetsAt: now.addingTimeInterval(86400))
        let a = LimitsHistory.row(session: s, week: w, now: now)
        let b = LimitsHistory.row(session: s, week: w, now: now.addingTimeInterval(300))
        #expect(a.key == b.key)
        #expect(a.line.hasSuffix("\n"))
        let obj =
            try JSONSerialization.jsonObject(
                with: Data(a.line.utf8)) as! [String: Any]
        #expect(obj["s"] as! Double == 42.1)
        #expect(obj["w"] as! Double == 67.3)
        #expect(obj["ts"] is String)
        #expect(obj["sr"] is String)
    }

    @Test func rowHandlesNils() throws {
        let a = LimitsHistory.row(session: nil, week: nil, now: now)
        let obj = try JSONSerialization.jsonObject(with: Data(a.line.utf8)) as! [String: Any]
        #expect(obj["s"] == nil)
        #expect(obj["sr"] == nil)
        #expect(obj["ts"] is String)
    }

    @Test func parseSkipsGarbageAndFiltersByDate() {
        let iso = ISO8601DateFormatter()
        let old = iso.string(from: now.addingTimeInterval(-100_000))
        let fresh = iso.string(from: now.addingTimeInterval(-100))
        let text = """
            {"ts":"\(old)","s":10,"w":20,"sr":null,"wr":null}
            not json
            {"ts":"\(fresh)","s":42.1,"w":67.3,"sr":null,"wr":null}
            """
        let pts = LimitsHistory.parse(text, since: now.addingTimeInterval(-86400))
        #expect(pts.count == 1)
        #expect(pts[0].s == 42.1)
        #expect(pts[0].w == 67.3)
    }

    @Test func appendDedupesSeedsAndHealsTornTail() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-tests-\(UUID().uuidString)")
        let url = dir.appendingPathComponent("limits-history.jsonl")
        defer { try? FileManager.default.removeItem(at: dir) }

        let s = LimitWindow(percent: 42.1, resetsAt: nil)
        let w = LimitWindow(percent: 67.3, resetsAt: nil)

        var h = LimitsHistory(url: url)
        h.append(session: s, week: w, now: now)
        h.append(session: s, week: w, now: now.addingTimeInterval(300))
        var text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.split(separator: "\n").count == 1)

        var h2 = LimitsHistory(url: url)
        h2.append(session: s, week: w, now: now.addingTimeInterval(600))
        text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.split(separator: "\n").count == 1)

        let handle = try FileHandle(forWritingTo: url)
        _ = try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"ts\":\"torn".utf8))
        try handle.close()
        var h3 = LimitsHistory(url: url)
        h3.append(
            session: LimitWindow(percent: 50, resetsAt: nil), week: w,
            now: now.addingTimeInterval(900))
        let raw = try String(contentsOf: url, encoding: .utf8)
        #expect(raw.split(separator: "\n").count == 3)
        let pts = LimitsHistory.parse(raw, since: .distantPast)
        #expect(pts.count == 2)
    }

    @Test func latestReadsLastValidLine() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("limits-history.jsonl")
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(LimitsHistory.latest(url: url) == nil)

        let iso = ISO8601DateFormatter()
        let ts = iso.string(from: now)
        let reset = iso.string(from: now.addingTimeInterval(3600))
        let text = """
            {"ts":"\(iso.string(from: now.addingTimeInterval(-600)))","s":10,"w":20}
            {"ts":"\(ts)","s":42.1,"w":67.3,"sr":"\(reset)","wr":null}
            {"ts":"torn
            """
        try Data(text.utf8).write(to: url)

        let latest = try #require(LimitsHistory.latest(url: url))
        #expect(abs(latest.date.timeIntervalSince(now)) < 1)
        #expect(latest.session?.percent == 42.1)
        #expect(latest.week?.percent == 67.3)
        let sr = try #require(latest.session?.resetsAt)
        #expect(abs(sr.timeIntervalSince(now.addingTimeInterval(3600))) < 1)
        #expect(latest.week?.resetsAt == nil)
    }

    @Test func mergeUnionsSortsAndDedupes() {
        let a = """
            {"ts":"2026-07-01T10:00:00Z","s":10,"w":5}
            {"ts":"2026-07-01T12:00:00Z","s":30,"w":6}
            """
        let b = """
            {"ts":"2026-07-01T11:00:00Z","s":20,"w":5}
            {"ts":"2026-07-01T12:00:00Z","s":30,"w":6}
            """
        let lines = LimitsHistory.merge(a, b).split(separator: "\n").map(String.init)
        #expect(lines.count == 3)
        #expect(lines[0].contains("10:00:00"))
        #expect(lines[1].contains("11:00:00"))
        #expect(lines[2].contains("12:00:00"))
        #expect(lines.contains { $0.contains("\"s\":10") })
        #expect(lines.contains { $0.contains("\"s\":20") })
        #expect(lines.contains { $0.contains("\"s\":30") })
    }

    @Test func mergeDropsGarbageKeepsValid() {
        let a = "not json\n{\"ts\":\"2026-07-01T10:00:00Z\",\"s\":10,\"w\":5}\n"
        let lines = LimitsHistory.merge(a, "").split(separator: "\n").map(String.init)
        #expect(lines.count == 1)
        #expect(lines[0].contains("10:00:00"))
    }

    @Test func providersAreStoredAndFilteredIndependently() throws {
        let claude = LimitsHistory.row(
            provider: .claude, session: LimitWindow(percent: 12, resetsAt: nil), week: nil,
            now: now)
        let codex = LimitsHistory.row(
            provider: .codex, session: nil, week: LimitWindow(percent: 48, resetsAt: nil),
            now: now)
        let text = claude.line + codex.line
        let claudePoints = LimitsHistory.parse(text, since: .distantPast, provider: .claude)
        let codexPoints = LimitsHistory.parse(text, since: .distantPast, provider: .codex)
        #expect(claudePoints.map(\.s) == [12])
        #expect(codexPoints.map(\.w) == [48])
    }
}

@Suite struct LimitsHistoryFableTests {
    let now = Date(timeIntervalSince1970: 1_787_000_000)

    @Test func fableRoundTripsAndChangesTheDedupeKey() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-tests-\(UUID().uuidString)")
        let url = dir.appendingPathComponent("limits-history.jsonl")
        defer { try? FileManager.default.removeItem(at: dir) }

        let session = LimitWindow(percent: 92, resetsAt: nil)
        let week = LimitWindow(percent: 68, resetsAt: nil)
        var history = LimitsHistory(url: url)
        history.append(
            session: session, week: week,
            fable: LimitWindow(percent: 45.5, resetsAt: now.addingTimeInterval(86400)), now: now)

        let latest = try #require(LimitsHistory.latest(url: url))
        #expect(latest.fable?.percent == 45.5)
        #expect(latest.fable?.resetsAt != nil)
        #expect(latest.session?.percent == 92)

        history.append(
            session: session, week: week,
            fable: LimitWindow(percent: 46, resetsAt: now.addingTimeInterval(86400)),
            now: now.addingTimeInterval(300))
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.split(separator: "\n").count == 2)
    }

    @Test func rowsWithoutFableStillDecode() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-tests-\(UUID().uuidString)")
        let url = dir.appendingPathComponent("limits-history.jsonl")
        defer { try? FileManager.default.removeItem(at: dir) }
        let iso = ISO8601DateFormatter()
        let line = """
            {"ts":"\(iso.string(from: now))","p":"claude","s":87,"w":67,"sr":null,"wr":null}
            """
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data((line + "\n").utf8).write(to: url)
        let latest = try #require(LimitsHistory.latest(url: url))
        #expect(latest.session?.percent == 87)
        #expect(latest.fable == nil)
    }
}
