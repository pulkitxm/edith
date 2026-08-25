import Darwin
import Foundation

public struct LimitsHistory {
    public struct Latest: Sendable {
        public let date: Date
        public let session: LimitWindow?
        public let week: LimitWindow?
        public let fable: LimitWindow?
    }

    public struct Snapshot: Sendable {
        public let providers: [LimitProvider]
        public let provider: LimitProvider
        public let latest: [LimitProvider: Latest]
        public let points: [LimitPoint]
    }

    public static var url: URL { Repo.limitsJSONL }

    private let fileURL: URL

    public init(url: URL = LimitsHistory.url) {
        self.fileURL = url
    }

    private struct Row: Codable {
        let ts: String
        let p: LimitProvider?
        let s: Double?
        let w: Double?
        let f: Double?
        let sr: String?
        let wr: String?
        let fr: String?
    }

    private static let iso = ISO8601DateFormatter()
    private static let decoder = JSONDecoder()
    private static let maximumTailScanBytes = 16 * 1_024 * 1_024

    public static func isValidDocument(_ text: String) -> Bool {
        let lines = text.split(separator: "\n")
        guard !lines.isEmpty else { return false }
        return lines.allSatisfy { line in
            guard let row = try? decoder.decode(Row.self, from: Data(line.utf8)) else {
                return false
            }
            return EdithDate.parseISO(row.ts) != nil
        }
    }

    public static func row(
        provider: LimitProvider = .claude, session: LimitWindow?, week: LimitWindow?,
        fable: LimitWindow? = nil, now: Date
    ) -> (
        key: String, line: String
    ) {
        let round1 = { (v: Double) in (v * 10).rounded() / 10 }
        let r = Row(
            ts: iso.string(from: now),
            p: provider,
            s: session.map { round1($0.percent) },
            w: week.map { round1($0.percent) },
            f: fable.map { round1($0.percent) },
            sr: session?.resetsAt.map { iso.string(from: $0) },
            wr: week?.resetsAt.map { iso.string(from: $0) },
            fr: fable?.resetsAt.map { iso.string(from: $0) })
        let key =
            "\(provider.rawValue)|\(r.s ?? -1)|\(r.w ?? -1)|\(r.f ?? -1)|\(r.sr ?? "-")|\(r.wr ?? "-")|\(r.fr ?? "-")"
        let data = (try? JSONEncoder().encode(r)) ?? Data("{}".utf8)
        return (key, String(decoding: data, as: UTF8.self) + "\n")
    }

    @discardableResult
    public mutating func append(
        provider: LimitProvider = .claude, session: LimitWindow?, week: LimitWindow?,
        fable: LimitWindow? = nil, now: Date = Date()
    ) -> Bool {
        let (key, line) = Self.row(
            provider: provider, session: session, week: week, fable: fable, now: now)
        do {
            try UsageDataLock.withLock(dataDirectory: fileURL.deletingLastPathComponent()) {
                let needsNewline = try Self.repairTrailingRow(at: fileURL)
                guard Self.latestKey(provider: provider, url: fileURL) != key else { return }
                var payload = Data(line.utf8)
                if needsNewline { payload.insert(UInt8(ascii: "\n"), at: 0) }
                try UsageDurableFile.append(payload, to: fileURL)
            }
            return true
        } catch {
            return false
        }
    }

    private static func latestKey(provider: LimitProvider, url: URL) -> String? {
        var result: String?
        FileTail.scanLinesReversed(url, maxScanBytes: maximumTailScanBytes) { data in
            guard let row = try? decoder.decode(Row.self, from: data),
                EdithDate.parseISO(row.ts) != nil,
                (row.p ?? .claude) == provider
            else { return true }
            result = key(for: row)
            return false
        }
        return result
    }

    private static func key(for row: Row) -> String {
        let provider = row.p ?? .claude
        return
            "\(provider.rawValue)|\(row.s ?? -1)|\(row.w ?? -1)|\(row.f ?? -1)|\(row.sr ?? "-")|\(row.wr ?? "-")|\(row.fr ?? "-")"
    }

    private static func repairTrailingRow(at url: URL) throws -> Bool {
        let descriptor = open(url.path, O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        if descriptor < 0, errno == ENOENT { return false }
        guard descriptor >= 0 else { throw UsageDataFileError.unsafe(url.path) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG else {
            throw UsageDataFileError.unsafe(url.path)
        }
        let end = try handle.seekToEnd()
        guard end > 0 else { return false }
        try handle.seek(toOffset: end - 1)
        if try handle.read(upToCount: 1) == Data("\n".utf8) { return false }
        let maximum = UInt64(1_048_576)
        let start = end > maximum ? end - maximum : 0
        try handle.seek(toOffset: start)
        let tail = try handle.readToEnd() ?? Data()
        let newline = tail.lastIndex(of: UInt8(ascii: "\n"))
        if start > 0, newline == nil { return true }
        let rowStart = newline.map { tail.index(after: $0) } ?? tail.startIndex
        let rowData = Data(tail[rowStart...])
        if (start == 0 || newline != nil),
            let row = try? decoder.decode(Row.self, from: rowData),
            EdithDate.parseISO(row.ts) != nil
        {
            return true
        }
        let repairedEnd =
            newline.map { start + UInt64(tail.distance(from: tail.startIndex, to: $0)) + 1 } ?? 0
        try handle.truncate(atOffset: repairedEnd)
        try handle.synchronize()
        return false
    }

    public static func latest(
        provider: LimitProvider = .claude, url: URL = LimitsHistory.url
    ) -> (
        date: Date, session: LimitWindow?, week: LimitWindow?, fable: LimitWindow?
    )? {
        guard let latest = latestProviders(providers: [provider], url: url)[provider] else {
            return nil
        }
        return (latest.date, latest.session, latest.week, latest.fable)
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
            if Task.isCancelled { break }
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
        guard
            let data = try? UsageDataFiles.readRegularFile(
                at: url, maximumBytes: UsageDataFiles.maximumLimitsHistoryBytes)
        else { return [] }
        return parse(String(decoding: data, as: UTF8.self), provider: provider)
    }

    public static func loadLatestPoint(
        provider: LimitProvider = .claude, url: URL = LimitsHistory.url
    ) -> LimitPoint? {
        guard let latest = latest(provider: provider, url: url) else { return nil }
        return LimitPoint(
            date: latest.date, s: latest.session?.percent, w: latest.week?.percent,
            sessionReset: latest.session?.resetsAt, weekReset: latest.week?.resetsAt)
    }

    public static func availableProviders(url: URL = LimitsHistory.url) -> [LimitProvider] {
        let found = Set(latestProviders(url: url).keys)
        return LimitProvider.allCases.filter(found.contains)
    }

    public static func latestProviders(
        providers: Set<LimitProvider> = Set(LimitProvider.allCases),
        url: URL = LimitsHistory.url
    ) -> [LimitProvider: Latest] {
        latestRows(url: url, providers: providers).reduce(into: [:]) { result, item in
            let (provider, row) = item
            result[provider] = latest(row: row)
        }
    }

    public static func loadLatestProviders(
        providers: Set<LimitProvider> = Set(LimitProvider.allCases),
        url: URL = LimitsHistory.url
    ) async -> [LimitProvider: Latest] {
        let load = Task.detached(priority: .utility) {
            latestProviders(providers: providers, url: url)
        }
        return await withTaskCancellationHandler {
            await load.value
        } onCancel: {
            load.cancel()
        }
    }

    public static func loadSnapshot(
        preferredProvider: LimitProvider, url: URL = LimitsHistory.url
    ) async -> Snapshot {
        let load = Task.detached(priority: .utility) {
            snapshot(preferredProvider: preferredProvider, url: url)
        }
        return await withTaskCancellationHandler {
            await load.value
        } onCancel: {
            load.cancel()
        }
    }

    private static func latestRows(
        url: URL, providers: Set<LimitProvider>
    ) -> [LimitProvider: Row] {
        var rows: [LimitProvider: Row] = [:]
        FileTail.scanLinesReversed(
            url, maxScanBytes: maximumTailScanBytes,
            shouldContinue: { !Task.isCancelled }
        ) { data in
            guard let row = try? decoder.decode(Row.self, from: data),
                EdithDate.parseISO(row.ts) != nil
            else { return true }
            let provider = row.p ?? .claude
            if providers.contains(provider), rows[provider] == nil { rows[provider] = row }
            return rows.count < providers.count
        }
        return rows
    }

    private static func snapshot(preferredProvider: LimitProvider, url: URL) -> Snapshot {
        var latest: [LimitProvider: Latest] = [:]
        var points: [LimitProvider: [LimitPoint]] = [:]
        FileTail.scanLinesReversed(
            url, maxScanBytes: maximumTailScanBytes,
            shouldContinue: { !Task.isCancelled }
        ) { data in
            guard let row = try? decoder.decode(Row.self, from: data),
                let date = EdithDate.parseISO(row.ts)
            else { return true }
            let provider = row.p ?? .claude
            if latest[provider] == nil {
                latest[provider] = self.latest(row: row)
            }
            points[provider, default: []].append(point(row: row, date: date))
            return true
        }
        let providers = LimitProvider.allCases.filter { latest[$0] != nil }
        let provider =
            providers.contains(preferredProvider)
            ? preferredProvider
            : providers.first ?? preferredProvider
        return Snapshot(
            providers: providers, provider: provider, latest: latest,
            points: points[provider, default: []].sorted { $0.date < $1.date })
    }

    private static func latest(row: Row) -> Latest? {
        guard let date = EdithDate.parseISO(row.ts) else { return nil }
        return Latest(
            date: date,
            session: row.s.map {
                LimitWindow(percent: $0, resetsAt: row.sr.flatMap(EdithDate.parseISO))
            },
            week: row.w.map {
                LimitWindow(percent: $0, resetsAt: row.wr.flatMap(EdithDate.parseISO))
            },
            fable: row.f.map {
                LimitWindow(percent: $0, resetsAt: row.fr.flatMap(EdithDate.parseISO))
            })
    }

    private static func point(row: Row, date: Date) -> LimitPoint {
        LimitPoint(
            date: date, s: row.s, w: row.w,
            sessionReset: row.sr.flatMap(EdithDate.parseISO),
            weekReset: row.wr.flatMap(EdithDate.parseISO))
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

public struct LimitPoint: Identifiable, Equatable, Sendable {
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
