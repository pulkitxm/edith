import Foundation

public struct UpdateCheckRecord: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case automatic
        case manual

        public var label: String {
            switch self {
            case .automatic: return "Automatic"
            case .manual: return "Manual"
            }
        }
    }

    public enum Outcome: String, Codable, Sendable {
        case upToDate
        case updateFound
        case failed
    }

    public let id: UUID
    public let date: Date
    public let kind: Kind
    public let outcome: Outcome
    public let version: String?
    public let detail: String?

    public init(
        id: UUID = UUID(), date: Date, kind: Kind, outcome: Outcome, version: String? = nil,
        detail: String? = nil
    ) {
        self.id = id
        self.date = date
        self.kind = kind
        self.outcome = outcome
        self.version = version
        self.detail = detail
    }

    public var summary: String {
        switch outcome {
        case .upToDate: return "Up to date"
        case .updateFound: return version.map { "Found \($0)" } ?? "Update found"
        case .failed: return detail?.isEmpty == false ? detail! : "Check failed"
        }
    }
}

public enum UpdateCheckLog {
    public static let limit = 200

    public static var url: URL { AppData.supportDir.appendingPathComponent("update-checks.json") }

    public static func load(from url: URL = UpdateCheckLog.url) -> [UpdateCheckRecord] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let records = try? decoder.decode([UpdateCheckRecord].self, from: data) else {
            return []
        }
        return records.sorted { $0.date > $1.date }
    }

    @discardableResult
    public static func append(
        _ record: UpdateCheckRecord, to url: URL = UpdateCheckLog.url
    ) -> [UpdateCheckRecord] {
        let records = Array(([record] + load(from: url)).prefix(limit))
        save(records, to: url)
        return records
    }

    public static func clear(at url: URL = UpdateCheckLog.url) {
        try? FileManager.default.removeItem(at: url)
    }

    public static func count(of kind: UpdateCheckRecord.Kind, in records: [UpdateCheckRecord])
        -> Int
    {
        records.filter { $0.kind == kind }.count
    }

    static func save(_ records: [UpdateCheckRecord], to url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(records) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

public struct UpdateCheckInterval: Identifiable, Equatable, Sendable {
    public let seconds: TimeInterval
    public let label: String

    public var id: TimeInterval { seconds }

    public init(seconds: TimeInterval, label: String) {
        self.seconds = seconds
        self.label = label
    }

    public static let choices: [UpdateCheckInterval] = [
        UpdateCheckInterval(seconds: 3_600, label: "Every hour"),
        UpdateCheckInterval(seconds: 21_600, label: "Every 6 hours"),
        UpdateCheckInterval(seconds: 43_200, label: "Every 12 hours"),
        UpdateCheckInterval(seconds: 86_400, label: "Every day"),
        UpdateCheckInterval(seconds: 604_800, label: "Every week"),
    ]

    public static let fallback = UpdateCheckInterval(seconds: 86_400, label: "Every day")

    public static let customTag: TimeInterval = -1

    public static let minimumSeconds: TimeInterval = 3_600

    public static let maximumSeconds: TimeInterval = 2_592_000

    public static func nearest(to seconds: TimeInterval) -> UpdateCheckInterval {
        choices.min { abs($0.seconds - seconds) < abs($1.seconds - seconds) } ?? fallback
    }

    public static func isPreset(_ seconds: TimeInterval) -> Bool {
        choices.contains { $0.seconds == seconds }
    }

    public static func clamp(_ seconds: TimeInterval) -> TimeInterval {
        guard seconds.isFinite else { return fallback.seconds }
        return min(max(seconds.rounded(), minimumSeconds), maximumSeconds)
    }

    public static func clampNotice(entered: TimeInterval, applied: TimeInterval) -> String? {
        guard entered.isFinite else { return "That is not a number, so nothing changed." }
        guard Int(entered.rounded()) != Int(applied.rounded()) else { return nil }
        if applied == minimumSeconds {
            return "Sparkle will not check more often than hourly, so this was raised to "
                + "\(Int(minimumSeconds)) seconds."
        }
        if applied == maximumSeconds {
            return "Capped at \(Int(maximumSeconds)) seconds, the longest interval Edith offers."
        }
        return "Rounded to \(Int(applied)) seconds."
    }

    public static func describe(_ seconds: TimeInterval) -> String {
        if let preset = choices.first(where: { $0.seconds == seconds }) { return preset.label }
        let total = Int(seconds.rounded())
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60
        var parts: [String] = []
        if days > 0 { parts.append("\(days)d") }
        if hours > 0 { parts.append("\(hours)h") }
        if minutes > 0 { parts.append("\(minutes)m") }
        if parts.isEmpty { parts.append("\(total)s") }
        return "Every " + parts.joined(separator: " ")
    }
}
