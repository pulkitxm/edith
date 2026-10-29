import CryptoKit
import Foundation

public enum UsageNativeFailure: Error, LocalizedError {
    case invalidInput(String)
    case capacity
    case unsafePath
    case archive(String)
    case network(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidInput(let source): "Invalid usage data for " + source
        case .capacity: "A usage input exceeded its safety size limit"
        case .unsafePath: "Usage storage must be a private regular file or directory"
        case .archive(let operation): "Usage archive could not " + operation
        case .network(let status): "Usage request failed with HTTP " + String(status)
        }
    }
}

final class UsageNativeIssues {
    private var failures: [String: (count: Int, example: String)] = [:]
    private var skippedLines: [String: Int] = [:]

    static func isolates(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        if case UsageNativeFailure.archive = error { return false }
        return true
    }

    func failed(source: String, item: String, error: Error) {
        let reason = String(error.localizedDescription.prefix(160))
        let current = failures[source]
        failures[source] = (
            (current?.count ?? 0) + 1, current?.example ?? item + ": " + reason
        )
    }

    func skipped(source: String, lines: Int) {
        if lines > 0 { skippedLines[source, default: 0] += lines }
    }

    var notes: [String] {
        let label = { (source: String) in UsageNativeAssembly.labels[source] ?? source }
        let failed = failures.keys.sorted().map { source -> String in
            let entry = failures[source]!
            return label(source) + ": skipped " + String(entry.count)
                + (entry.count == 1 ? " source (" : " sources (e.g. ") + entry.example
                + "); other receipts were collected"
        }
        let lines = skippedLines.keys.sorted().map { source in
            label(source) + ": skipped " + String(skippedLines[source]!)
                + " line(s) larger than the safety limit"
        }
        return failed + lines
    }
}

struct UsageNativeTokens: Codable, Equatable, Sendable {
    var input: Double = 0
    var output: Double = 0
    var creation: Double = 0
    var read: Double = 0
    var creationHour: Double = 0
    var total: Double { input + output + creation + read }

    static func number(_ value: Any?, default fallback: Double = 0) throws -> Double {
        guard let value else { return fallback }
        guard let number = value as? NSNumber,
            CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite,
            number.doubleValue >= 0, number.doubleValue <= 9_007_199_254_740_991,
            number.doubleValue.rounded(.towardZero) == number.doubleValue
        else { throw UsageNativeFailure.invalidInput("token count") }
        return number.doubleValue
    }

    static func wireNumber(_ value: Any?) throws -> Double {
        if let text = value as? String {
            guard text.range(of: "^(0|[1-9][0-9]{0,15})$", options: .regularExpression) != nil,
                let number = Double(text)
            else {
                throw UsageNativeFailure.invalidInput("token count")
            }
            return try self.number(NSNumber(value: number))
        }
        return try number(value)
    }

    static func amount(_ value: Any?) throws -> Double? {
        guard let value, !(value is NSNull) else { return nil }
        let number: Double?
        if let value = value as? String {
            number = Double(value)
        } else if let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() {
            number = value.doubleValue
        } else {
            number = nil
        }
        guard let number, number.isFinite, number >= 0, number <= 1_000_000_000_000 else {
            throw UsageNativeFailure.invalidInput("cost")
        }
        return number
    }

    static func anthropic(_ usage: [String: Any]) throws -> Self {
        let cache = usage["cache_creation"] as? [String: Any] ?? [:]
        let hour = try number(cache["ephemeral_1h_input_tokens"])
        let short = try number(cache["ephemeral_5m_input_tokens"])
        return try .init(
            input: number(usage["input_tokens"]), output: number(usage["output_tokens"]),
            creation: max(number(usage["cache_creation_input_tokens"]), hour + short),
            read: number(usage["cache_read_input_tokens"]), creationHour: hour)
    }

    static func openAI(_ usage: [String: Any]) throws -> Self {
        let inclusive = try number(usage["input_tokens"])
        let read = try number(usage["cached_input_tokens"])
        let creation = try number(usage["cache_write_input_tokens"])
        guard read + creation <= inclusive else {
            throw UsageNativeFailure.invalidInput("cached input count")
        }
        return try .init(
            input: inclusive - read - creation, output: number(usage["output_tokens"]),
            creation: creation, read: read)
    }

    static func - (left: Self, right: Self) -> Self {
        .init(
            input: max(0, left.input - right.input), output: max(0, left.output - right.output),
            creation: max(0, left.creation - right.creation), read: max(0, left.read - right.read))
    }
}

struct UsageNativeEvent: Codable, Equatable, Sendable {
    var source: String
    var identity: String?
    var session: String
    var model: String
    var timestamp: Date
    var cwd: String
    var title: String?
    var tokens: UsageNativeTokens
    var recordedCost: Double?
    var serviceTier: String?
    var detailAvailable = true
    var reportingDay: String?
    var observationPriority: Int?
    var traceID: String?
    var estimated = false
    var receiptID: String?

    var canonicalData: Data {
        get throws {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return try encoder.encode(self)
        }
    }
}

struct UsageNativeParsedRecord: Sendable {
    let offset: Int
    let end: Int
    let event: UsageNativeEvent
}

struct UsageNativeFileSnapshot: Sendable {
    let path: String
    let size: Int
    let completeBytes: Int
    let modified: Double
    let hash: String
    let prefixHash: String
    let records: [UsageNativeParsedRecord]
    var appended: Bool?
    var skippedLines = 0
    var state: String?
}

enum UsageNativeJSON {
    static func object(_ data: Data) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageNativeFailure.invalidInput("JSON document")
        }
        return value
    }

    static func encode(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }

    private static let hexDigits = Array("0123456789abcdef".utf8)

    static func hex<Bytes: Sequence>(_ bytes: Bytes) -> String where Bytes.Element == UInt8 {
        var digits = [UInt8]()
        digits.reserveCapacity(64)
        for byte in bytes {
            digits.append(hexDigits[Int(byte >> 4)])
            digits.append(hexDigits[Int(byte & 15)])
        }
        return String(decoding: digits, as: UTF8.self)
    }

    static func hash(_ data: Data) -> String { hex(SHA256.hash(data: data)) }

    static func hash(_ value: String) -> String { hash(Data(value.utf8)) }

    static func date(_ value: Any?) -> Date? {
        if let number = value as? NSNumber {
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            let seconds =
                number.doubleValue > 100_000_000_000
                ? number.doubleValue / 1000 : number.doubleValue
            return seconds.isFinite && seconds > 0 && seconds < 253_402_300_800
                ? Date(timeIntervalSince1970: seconds) : nil
        }
        guard let value = value as? String else { return nil }
        if let number = Double(value), number > 0 { return date(NSNumber(value: number)) }
        if let parsed = utcTimestamp(value) { return parsed }
        return fractionalFormatter.date(from: value) ?? plainFormatter.date(from: value)
    }

    static func utcTimestamp(_ value: String) -> Date? {
        var bytes = Array(value.utf8)
        guard bytes.count >= 20, bytes.count <= 40, bytes.last == 90 else { return nil }
        bytes.removeLast()
        func digits(_ range: Range<Int>) -> Int? {
            var total = 0
            for index in range {
                let digit = Int(bytes[index]) - 48
                guard (0...9).contains(digit) else { return nil }
                total = total * 10 + digit
            }
            return total
        }
        guard bytes[4] == 45, bytes[7] == 45, bytes[10] == 84, bytes[13] == 58, bytes[16] == 58,
            let year = digits(0..<4), let month = digits(5..<7), let day = digits(8..<10),
            let hour = digits(11..<13), let minute = digits(14..<16), let second = digits(17..<19),
            year >= 1970, (1...12).contains(month), (1...31).contains(day), hour < 24, minute < 60, second < 60
        else { return nil }
        var fraction = 0.0
        if bytes.count > 19 {
            guard bytes[19] == 46, bytes.count > 20, bytes.count <= 29 else { return nil }
            var scale = 0.1
            for index in 20..<bytes.count {
                let digit = Int(bytes[index]) - 48
                guard (0...9).contains(digit) else { return nil }
                fraction += Double(digit) * scale
                scale /= 10
            }
        }
        let shiftedYear = month <= 2 ? year - 1 : year
        let era = shiftedYear / 400
        let yearOfEra = shiftedYear - era * 400
        let monthIndex = (month + 9) % 12
        let dayOfYear = (153 * monthIndex + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        let days = era * 146_097 + dayOfEra - 719_468
        let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
        let daysInMonth = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        guard day <= daysInMonth[month - 1] else { return nil }
        let seconds = Double(days) * 86_400 + Double(hour * 3600 + minute * 60 + second)
        return Date(timeIntervalSince1970: seconds + fraction)
    }

    private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let plainFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func text(_ value: Any?, maximum: Int = 4096) -> String? {
        guard let text = value as? String, !text.isEmpty, text.utf8.count <= maximum,
            !text.unicodeScalars.contains(where: { $0.value == 0 })
        else { return nil }
        return text
    }

    static func title(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("<") else { return nil }
        return String(trimmed.prefix(80))
    }
}
