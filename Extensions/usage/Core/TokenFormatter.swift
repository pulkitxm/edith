import Foundation

public enum TokenFormatter {
    public static func compact(_ value: Double) -> String {
        let magnitude = abs(value)
        if magnitude >= 999_950_000 { return String(format: "%.2fB", value / 1_000_000_000) }
        if magnitude >= 999_950 { return String(format: "%.1fM", value / 1_000_000) }
        if magnitude >= 999.5 { return String(format: "%.1fk", value / 1_000) }
        return String(format: "%.0f", value)
    }
}
