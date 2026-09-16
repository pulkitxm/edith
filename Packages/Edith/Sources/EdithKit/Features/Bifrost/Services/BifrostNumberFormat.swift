import Foundation

public enum BifrostNumberFormat {
    public static let significantDigits = 10

    public static func plain(_ value: Double) -> String {
        guard value.isFinite else { return "" }
        let rounded = rounded(value)
        if rounded == rounded.rounded(), abs(rounded) < 1e15 {
            return String(Int64(rounded))
        }
        var text = String(format: "%.\(significantDigits)g", rounded)
        if text.contains("."), !text.contains("e"), !text.contains("E") {
            while text.hasSuffix("0") { text.removeLast() }
            if text.hasSuffix(".") { text.removeLast() }
        }
        return text
    }

    public static func grouped(_ value: Double) -> String {
        let text = plain(value)
        guard !text.contains("e"), !text.contains("E") else { return text }
        let negative = text.hasPrefix("-")
        let body = negative ? String(text.dropFirst()) : text
        let parts = body.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard let whole = parts.first, whole.count > 3 else { return text }
        var digits: [Character] = []
        for (offset, character) in whole.reversed().enumerated() {
            if offset > 0, offset.isMultiple(of: 3) { digits.append(",") }
            digits.append(character)
        }
        var grouped = String(digits.reversed())
        if parts.count == 2 { grouped += "." + parts[1] }
        return negative ? "-" + grouped : grouped
    }

    private static func rounded(_ value: Double) -> Double {
        guard value != 0, value.isFinite else { return value }
        let magnitude = floor(log10(abs(value)))
        let scale = pow(10, Double(significantDigits - 1) - magnitude)
        guard scale.isFinite, scale != 0 else { return value }
        let scaled = (value * scale).rounded()
        guard scaled.isFinite else { return value }
        return scaled / scale
    }
}
