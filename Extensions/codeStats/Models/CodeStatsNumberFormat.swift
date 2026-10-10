import EdithExtensionSupport
import Foundation

public enum CodeStatsNumberFormat {
    public static let compactThreshold = 10_000

    private static let units: [(scale: Double, suffix: String)] = [
        (1_000, "K"), (1_000_000, "M"), (1_000_000_000, "B"),
    ]

    public static func grouped(_ value: Int) -> String {
        let digits = String(value.magnitude)
        var result = ""
        result.reserveCapacity(digits.count + digits.count / 3 + 1)
        for (index, digit) in digits.enumerated() {
            if index > 0, (digits.count - index) % 3 == 0 { result.append(",") }
            result.append(digit)
        }
        return value < 0 ? "-" + result : result
    }

    public static func decimal(_ value: Double, fractionDigits: Int = 1) -> String {
        guard value.isFinite else { return "0" }
        let digits = max(fractionDigits, 0)
        var scale = 1
        for _ in 0..<digits { scale *= 10 }
        let scaled = Int((abs(value) * Double(scale)).rounded())
        let whole = grouped(scaled / scale)
        let sign = value < 0 && scaled != 0 ? "-" : ""
        guard digits > 0 else { return sign + whole }
        let fraction = String(scaled % scale)
        return sign + whole + "." + String(repeating: "0", count: digits - fraction.count)
            + fraction
    }

    public static func compact(_ value: Int) -> String {
        guard value.magnitude >= UInt(compactThreshold) else { return grouped(value) }
        let magnitude = Double(value.magnitude)
        var index = units.lastIndex { magnitude >= $0.scale } ?? 0
        var scaled = (magnitude / units[index].scale * 10).rounded() / 10
        if scaled >= 1_000, index + 1 < units.count {
            index += 1
            scaled = (magnitude / units[index].scale * 10).rounded() / 10
        }
        let text =
            scaled == scaled.rounded()
            ? decimal(scaled, fractionDigits: 0) : decimal(scaled, fractionDigits: 1)
        return (value < 0 ? "-" : "") + text + units[index].suffix
    }

    public static func signed(_ value: Int) -> String {
        value > 0 ? "+" + grouped(value) : grouped(value)
    }

    public static func percent(_ value: Double, fractionDigits: Int = 0) -> String {
        decimal(value, fractionDigits: fractionDigits) + "%"
    }

    public static func signedPercent(_ value: Double) -> String {
        let text = percent(value)
        return value > 0 && text != "0%" ? "+" + text : text
    }
}
