import Foundation
import Testing
@testable import Edith

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
}
