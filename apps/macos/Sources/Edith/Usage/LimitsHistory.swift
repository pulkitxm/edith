import Foundation

struct LimitsHistory {
    static var url: URL {
        Repo.root.appendingPathComponent("apps/dashboard/data/limits-history.jsonl")
    }

    private let fileURL: URL

    init(url: URL = LimitsHistory.url) {
        self.fileURL = url
    }

    private var lastKey: String?
    private var seeded = false

    private struct Row: Codable {
        let ts: String
        let s: Double?
        let w: Double?
        let sr: String?
        let wr: String?
    }

    private static let iso = ISO8601DateFormatter()

    static func row(session: LimitWindow?, week: LimitWindow?, now: Date) -> (
        key: String, line: String
    ) {
        let round1 = { (v: Double) in (v * 10).rounded() / 10 }
        let r = Row(
            ts: iso.string(from: now),
            s: session.map { round1($0.percent) },
            w: week.map { round1($0.percent) },
            sr: session?.resetsAt.map { iso.string(from: $0) },
            wr: week?.resetsAt.map { iso.string(from: $0) })
        let key = "\(r.s ?? -1)|\(r.w ?? -1)|\(r.sr ?? "-")|\(r.wr ?? "-")"
        let data = (try? JSONEncoder().encode(r)) ?? Data("{}".utf8)
        return (key, String(decoding: data, as: UTF8.self) + "\n")
    }

    mutating func append(session: LimitWindow?, week: LimitWindow?, now: Date = Date()) {
        if !seeded { seed() }
        let (key, line) = Self.row(session: session, week: week, now: now)
        guard key != lastKey else { return }
        lastKey = key
        let url = fileURL
        let fm = FileManager.default
        try? fm.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) {
            try? Data(line.utf8).write(to: url)
            return
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            var payload = Data(line.utf8)
            if let end = try? handle.seekToEnd(), end > 0 {
                try? handle.seek(toOffset: end - 1)
                let last = (try? handle.read(upToCount: 1)) ?? nil
                if last != Data("\n".utf8) {
                    payload.insert(UInt8(ascii: "\n"), at: 0)
                }
            }
            try? handle.write(contentsOf: payload)
        }
    }

    private mutating func seed() {
        seeded = true
        guard let data = try? Data(contentsOf: fileURL),
            let text = String(data: data, encoding: .utf8)
        else { return }
        guard let line = text.split(separator: "\n").last,
            let row = try? JSONDecoder().decode(Row.self, from: Data(line.utf8))
        else { return }
        lastKey = "\(row.s ?? -1)|\(row.w ?? -1)|\(row.sr ?? "-")|\(row.wr ?? "-")"
    }

    static func parse(_ text: String, since: Date) -> [LimitPoint] {
        var out: [LimitPoint] = []
        let decoder = JSONDecoder()
        for line in text.split(separator: "\n") {
            guard let row = try? decoder.decode(Row.self, from: Data(line.utf8)),
                let date = UsageStore.parseISO(row.ts), date >= since
            else { continue }
            out.append(LimitPoint(date: date, s: row.s, w: row.w))
        }
        return out.sorted { $0.date < $1.date }
    }

    static func merge(_ a: String, _ b: String) -> String {
        var seen = Set<String>()
        var rows: [(Date, String)] = []
        let decoder = JSONDecoder()
        for text in [a, b] {
            for sub in text.split(separator: "\n", omittingEmptySubsequences: true) {
                let line = String(sub)
                if seen.contains(line) { continue }
                guard let row = try? decoder.decode(Row.self, from: Data(line.utf8)),
                    let ts = UsageStore.parseISO(row.ts)
                else { continue }
                seen.insert(line)
                rows.append((ts, line))
            }
        }
        rows.sort { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }
        return rows.isEmpty ? "" : rows.map(\.1).joined(separator: "\n") + "\n"
    }
}

struct LimitPoint: Identifiable, Equatable {
    let date: Date
    let s: Double?
    let w: Double?
    var id: Date { date }
}
