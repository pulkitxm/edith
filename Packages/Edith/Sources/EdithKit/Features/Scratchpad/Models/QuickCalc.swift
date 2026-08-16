import Foundation

public enum QuickCalc {
    public static func evaluate(_ input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let converted = UnitConversion.convert(trimmed) { return converted }
        var parser = ArithmeticParser(trimmed)
        guard let value = parser.parse() else { return nil }
        return format(value)
    }

    static func format(_ value: Double) -> String {
        guard value.isFinite else { return "∞" }
        if value == value.rounded(), abs(value) < 1e15 {
            return String(format: "%.0f", value)
        }
        return String(format: "%.6g", value)
    }
}

struct ArithmeticParser {
    private let scalars: [Character]
    private var index = 0

    init(_ input: String) { scalars = Array(input) }

    mutating func parse() -> Double? {
        guard let value = parseExpression() else { return nil }
        skipSpaces()
        guard index == scalars.count else { return nil }
        return value
    }

    private mutating func parseExpression() -> Double? {
        guard var value = parseTerm() else { return nil }
        while true {
            skipSpaces()
            guard index < scalars.count, scalars[index] == "+" || scalars[index] == "-" else {
                break
            }
            let op = scalars[index]
            index += 1
            guard let rhs = parseTerm() else { return nil }
            value = op == "+" ? value + rhs : value - rhs
        }
        return value
    }

    private mutating func parseTerm() -> Double? {
        guard var value = parseFactor() else { return nil }
        while true {
            skipSpaces()
            guard index < scalars.count, scalars[index] == "*" || scalars[index] == "/" else {
                break
            }
            let op = scalars[index]
            index += 1
            guard let rhs = parseFactor() else { return nil }
            if op == "/" {
                guard rhs != 0 else { return nil }
                value /= rhs
            } else {
                value *= rhs
            }
        }
        return value
    }

    private mutating func parseFactor() -> Double? {
        skipSpaces()
        guard index < scalars.count else { return nil }
        if scalars[index] == "-" {
            index += 1
            return parseFactor().map { -$0 }
        }
        if scalars[index] == "+" {
            index += 1
            return parseFactor()
        }
        if scalars[index] == "(" {
            index += 1
            guard let value = parseExpression() else { return nil }
            skipSpaces()
            guard index < scalars.count, scalars[index] == ")" else { return nil }
            index += 1
            return value
        }
        return parseNumber()
    }

    private mutating func parseNumber() -> Double? {
        let start = index
        var seenDot = false
        while index < scalars.count,
            scalars[index].isNumber || (scalars[index] == "." && !seenDot)
        {
            if scalars[index] == "." { seenDot = true }
            index += 1
        }
        guard index > start else { return nil }
        return Double(String(scalars[start..<index]))
    }

    private mutating func skipSpaces() {
        while index < scalars.count, scalars[index] == " " { index += 1 }
    }
}
