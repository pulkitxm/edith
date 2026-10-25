import EdithExtensionSupport
import Foundation

public enum CompactDuration {
    private static let units: [(seconds: Int, label: String)] = [
        (86_400, "d"), (3_600, "h"), (60, "m"), (1, "s"),
    ]

    public static func text(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return "\(Int(seconds))s" }
        if seconds < 3_600 { return "\(Int(seconds / 60))m" }
        if seconds < 86_400 { return "\(Int(seconds / 3_600))h" }
        return "\(Int(seconds / 86_400))d"
    }

    public static func detailed(_ seconds: TimeInterval, showsSeconds: Bool = true) -> String {
        let exact = seconds.isFinite ? Int(min(max(0, seconds), Double(Int.max / 2))) : 0
        let total = showsSeconds || exact < 60 ? exact : exact / 60 * 60
        guard let index = units.firstIndex(where: { total >= $0.seconds }) else { return "0s" }
        let unit = units[index]
        let text = "\(total / unit.seconds)\(unit.label)"
        guard index + 1 < units.count else { return text }
        let next = units[index + 1]
        let rest = total % unit.seconds / next.seconds
        return rest > 0 ? "\(text) \(rest)\(next.label)" : text
    }
}
