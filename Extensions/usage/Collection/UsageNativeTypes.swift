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
        case .capacity: "Usage collection exceeded its admission limit"
        case .unsafePath: "Usage storage must be a private regular file or directory"
        case .archive(let operation): "Usage archive could not " + operation
        case .network(let status): "Usage request failed with HTTP " + String(status)
        }
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

    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

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
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

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
