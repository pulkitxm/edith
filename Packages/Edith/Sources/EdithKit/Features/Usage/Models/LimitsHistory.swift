import Foundation

public struct LimitsHistory {
    public static var url: URL { Repo.limitsJSONL }

    private let fileURL: URL

    public init(url: URL = LimitsHistory.url) {
        self.fileURL = url
    }

    private var lastKeys: [LimitProvider: String] = [:]
    private var seeded = false

    private struct Row: Codable {
        let ts: String
        let p: LimitProvider?
        let s: Double?
        let w: Double?
        let sr: String?
        let wr: String?
    }

    private static let iso = ISO8601DateFormatter()
    private static let decoder = JSONDecoder()

    public static func row(
        provider: LimitProvider = .claude, session: LimitWindow?, week: LimitWindow?, now: Date
    ) -> (
        key: String, line: String
    ) {
        let round1 = { (v: Double) in (v * 10).rounded() / 10 }
        let r = Row(
            ts: iso.string(from: now),
            p: provider,
            s: session.map { round1($0.percent) },
            w: week.map { round1($0.percent) },
            sr: session?.resetsAt.map { iso.string(from: $0) },
            wr: week?.resetsAt.map { iso.string(from: $0) })
        let key = "\(provider.rawValue)|\(r.s ?? -1)|\(r.w ?? -1)|\(r.sr ?? "-")|\(r.wr ?? "-")"
        let data = (try? JSONEncoder().encode(r)) ?? Data("{}".utf8)
        return (key, String(decoding: data, as: UTF8.self) + "\n")
    }

    public mutating func append(
        provider: LimitProvider = .claude, session: LimitWindow?, week: LimitWindow?,
        now: Date = Date()
    ) {
        if !seeded { seed() }
        let (key, line) = Self.row(provider: provider, session: session, week: week, now: now)
        guard key != lastKeys[provider] else { return }
        lastKeys[provider] = key
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
        for line in text.split(separator: "\n").reversed() {
            guard let row = try? Self.decoder.decode(Row.self, from: Data(line.utf8)) else {
                continue
            }
            let provider = row.p ?? .claude
            guard lastKeys[provider] == nil else { continue }
            lastKeys[provider] =
                "\(provider.rawValue)|\(row.s ?? -1)|\(row.w ?? -1)|\(row.sr ?? "-")|\(row.wr ?? "-")"
        }
    }

    public static func latest(
        provider: LimitProvider = .claude, url: URL = LimitsHistory.url
    ) -> (
        date: Date, session: LimitWindow?, week: LimitWindow?
    )? {
        let text = FileTail.read(url, maxBytes: 8192)
        for line in text.split(separator: "\n").reversed() {
            guard let row = try? Self.decoder.decode(Row.self, from: Data(line.utf8)),
                let date = EdithDate.parseISO(row.ts), (row.p ?? .claude) == provider
            else { continue }
            return (
                date: date,
                session: row.s.map {
                    LimitWindow(percent: $0, resetsAt: row.sr.flatMap(EdithDate.parseISO))
                },
                week: row.w.map {
                    LimitWindow(percent: $0, resetsAt: row.wr.flatMap(EdithDate.parseISO))
                }
            )
        }
        return nil
    }

    public static func parse(
        _ text: String, since: Date, provider: LimitProvider = .claude
    ) -> [LimitPoint] {
        parseRows(text, since: since, provider: provider)
    }

    public static func parse(
        _ text: String, since: Date? = nil, provider: LimitProvider = .claude
    ) -> [LimitPoint] {
        parseRows(text, since: since, provider: provider)
    }

    private static func parseRows(
        _ text: String, since: Date?, provider: LimitProvider
    ) -> [LimitPoint] {
        var out: [LimitPoint] = []
        for line in text.split(separator: "\n") {
            guard let row = try? Self.decoder.decode(Row.self, from: Data(line.utf8)),
                let date = EdithDate.parseISO(row.ts), since.map({ date >= $0 }) ?? true,
                (row.p ?? .claude) == provider
            else { continue }
            out.append(
                LimitPoint(
                    date: date, s: row.s, w: row.w,
                    sessionReset: row.sr.flatMap(EdithDate.parseISO),
                    weekReset: row.wr.flatMap(EdithDate.parseISO)))
        }
        return out.sorted { $0.date < $1.date }
    }

    public static func loadAll(
        provider: LimitProvider = .claude, url: URL = LimitsHistory.url
    ) -> [LimitPoint] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return parse(text, provider: provider)
    }

    public static func loadLatestPoint(
        provider: LimitProvider = .claude, url: URL = LimitsHistory.url
    ) -> LimitPoint? {
        let text = FileTail.read(url, maxBytes: 8192)
        return parse(text, provider: provider).last
    }

    public static func availableProviders(url: URL = LimitsHistory.url) -> [LimitProvider] {
        let text = FileTail.read(url, maxBytes: 65_536)
        let found = Set(
            text.split(separator: "\n").compactMap { line in
                (try? decoder.decode(Row.self, from: Data(line.utf8))).map { $0.p ?? .claude }
            })
        return LimitProvider.allCases.filter(found.contains)
    }

    public static func downsample(
        _ rows: [LimitPoint], now: Date, rawWindow: TimeInterval = 7 * 86400
    ) -> [LimitPoint] {
        let cutoff = now.addingTimeInterval(-rawWindow)
        var buckets: [TimeInterval: LimitPoint] = [:]
        var raw: [LimitPoint] = []
        for row in rows {
            if row.date >= cutoff {
                raw.append(row)
                continue
            }
            let bucket = (row.date.timeIntervalSince1970 / 3600).rounded(.down) * 3600
            if let current = buckets[bucket] {
                buckets[bucket] = LimitPoint(
                    date: Date(timeIntervalSince1970: bucket),
                    s: [current.s, row.s].compactMap { $0 }.max(),
                    w: [current.w, row.w].compactMap { $0 }.max(),
                    sessionReset: row.sessionReset,
                    weekReset: row.weekReset)
            } else {
                buckets[bucket] = LimitPoint(
                    date: Date(timeIntervalSince1970: bucket), s: row.s, w: row.w,
                    sessionReset: row.sessionReset, weekReset: row.weekReset)
            }
        }
        return (Array(buckets.values) + raw).sorted { $0.date < $1.date }
    }

    public static func resetMarkers(
        _ points: [LimitPoint], minGap: TimeInterval = 20 * 60
    ) -> [LimitResetMarker] {
        guard points.count > 1 else { return [] }
        var markers: [LimitResetMarker] = []
        var lastSession: Date?
        var lastWeekly: Date?
        for index in 1..<points.count {
            let previous = points[index - 1]
            let current = points[index]
            if let before = previous.sessionReset, let after = current.sessionReset,
                before != after,
                lastSession.map({ current.date.timeIntervalSince($0) > minGap }) ?? true
            {
                markers.append(LimitResetMarker(date: current.date, session: true))
                lastSession = current.date
            }
            if let before = previous.weekReset, let after = current.weekReset,
                before != after,
                lastWeekly.map({ current.date.timeIntervalSince($0) > minGap }) ?? true
            {
                markers.append(LimitResetMarker(date: current.date, session: false))
                lastWeekly = current.date
            }
        }
        return markers
    }

    public static func merge(_ a: String, _ b: String) -> String {
        var seen = Set<String>()
        var rows: [(Date, String)] = []
        for text in [a, b] {
            for sub in text.split(separator: "\n", omittingEmptySubsequences: true) {
                let line = String(sub)
                if seen.contains(line) { continue }
                guard let row = try? Self.decoder.decode(Row.self, from: Data(line.utf8)),
                    let ts = EdithDate.parseISO(row.ts)
                else { continue }
                seen.insert(line)
                rows.append((ts, line))
            }
        }
        rows.sort { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }
        return rows.isEmpty ? "" : rows.map(\.1).joined(separator: "\n") + "\n"
    }
}

public struct LimitPoint: Identifiable, Equatable {
    public let date: Date
    public let s: Double?
    public let w: Double?
    public let sessionReset: Date?
    public let weekReset: Date?
    public var id: Date { date }

    public init(
        date: Date, s: Double?, w: Double?, sessionReset: Date? = nil, weekReset: Date? = nil
    ) {
        self.date = date
        self.s = s
        self.w = w
        self.sessionReset = sessionReset
        self.weekReset = weekReset
    }
}

public struct LimitResetMarker: Identifiable, Equatable {
    public let date: Date
    public let session: Bool
    public var id: String { "\(date.timeIntervalSince1970)-\(session)" }

    public init(date: Date, session: Bool) {
        self.date = date
        self.session = session
    }
}
