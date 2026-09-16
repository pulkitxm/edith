import Foundation

public struct BifrostConversion: Equatable, Sendable {
    public let value: Double
    public let source: BifrostUnit
    public let target: BifrostUnit
    public let result: Double

    public var display: String {
        "\(BifrostNumberFormat.grouped(result)) \(target.symbol)"
    }

    public var detail: String {
        let left = "\(BifrostNumberFormat.grouped(value)) \(source.name(for: value))"
        let right = "\(BifrostNumberFormat.grouped(result)) \(target.name(for: result))"
        return "\(left) = \(right)"
    }

    public var copyText: String {
        BifrostNumberFormat.plain(result)
    }
}

public enum BifrostConversionParser {
    static let separators = [" in ", " to ", " into ", " as ", " -> ", " => ", " > "]

    public static func parse(_ input: String) -> BifrostConversion? {
        let normalized = normalize(input)
        guard !normalized.isEmpty, normalized.count <= 200 else { return nil }
        if let question = parseQuestion(normalized) { return question }
        for separator in separators {
            var searchStart = normalized.startIndex
            while let range = normalized.range(
                of: separator, range: searchStart..<normalized.endIndex)
            {
                let left = String(normalized[normalized.startIndex..<range.lowerBound])
                let right = String(normalized[range.upperBound...])
                if let conversion = build(left: left, right: right) { return conversion }
                searchStart =
                    range.lowerBound < normalized.endIndex
                    ? normalized.index(after: range.lowerBound) : normalized.endIndex
            }
        }
        return nil
    }

    static func normalize(_ input: String) -> String {
        var text = input.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        for (symbol, replacement) in [("->", " -> "), ("=>", " => "), ("\u{2192}", " -> ")] {
            text = text.replacingOccurrences(of: symbol, with: replacement)
        }
        if text.hasPrefix("convert ") { text = String(text.dropFirst("convert ".count)) }
        let parts = text.split(whereSeparator: \.isWhitespace)
        return parts.joined(separator: " ")
    }

    private static func parseQuestion(_ text: String) -> BifrostConversion? {
        let openings = ["how many ", "how much "]
        guard let opening = openings.first(where: { text.hasPrefix($0) }) else { return nil }
        let body = String(text.dropFirst(opening.count))
        for keyword in [" is ", " are ", " in ", " make ", " makes "] {
            guard let range = body.range(of: keyword) else { continue }
            let target = String(body[body.startIndex..<range.lowerBound])
            let amount = String(body[range.upperBound...])
            if let conversion = build(left: amount, right: target) { return conversion }
        }
        return nil
    }

    static func build(left: String, right: String) -> BifrostConversion? {
        guard let target = unit(in: right), let measurement = measurement(in: left) else {
            return nil
        }
        guard measurement.unit.dimension == target.dimension,
            let result = BifrostUnitCatalog.convert(
                measurement.value, from: measurement.unit, to: target)
        else { return nil }
        return BifrostConversion(
            value: measurement.value, source: measurement.unit, target: target, result: result)
    }

    static func unit(in text: String) -> BifrostUnit? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return BifrostUnitCatalog.unit(alias: trimmed)
    }

    static func measurement(in text: String) -> (value: Double, unit: BifrostUnit)? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let tokens = trimmed.split(separator: " ").map(String.init)
        guard !tokens.isEmpty else { return nil }
        for count in stride(from: min(3, tokens.count), through: 1, by: -1) {
            let suffix = tokens.suffix(count).joined(separator: " ")
            let prefix = tokens.dropLast(count).joined(separator: " ")
            if let unit = BifrostUnitCatalog.unit(alias: suffix),
                let value = amount(in: prefix)
            {
                return (value, unit)
            }
        }
        guard let split = splitGluedUnit(tokens[tokens.count - 1]) else { return nil }
        let prefix = tokens.dropLast().joined(separator: " ")
        guard let value = amount(in: prefix + " " + split.amount) else { return nil }
        return (value, split.unit)
    }

    private static func splitGluedUnit(_ token: String) -> (amount: String, unit: BifrostUnit)? {
        let characters = Array(token)
        var boundary = characters.count
        while boundary > 0, !characters[boundary - 1].isNumber {
            boundary -= 1
        }
        guard boundary > 0, boundary < characters.count else { return nil }
        let suffix = String(characters[boundary...])
        guard let unit = BifrostUnitCatalog.unit(alias: suffix) else { return nil }
        return (String(characters[..<boundary]), unit)
    }

    private static func amount(in text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return 1 }
        if trimmed == "a" || trimmed == "an" || trimmed == "one" { return 1 }
        return BifrostCalculator.value(of: trimmed)
    }
}
