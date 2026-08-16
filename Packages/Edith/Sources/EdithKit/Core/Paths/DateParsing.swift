import Foundation

public enum EdithDate {
    private static let iso = ISO8601DateFormatter()

    public static func isoString(_ date: Date) -> String {
        iso.string(from: date)
    }

    public static func parseISO(_ s: String?) -> Date? {
        guard var s else { return nil }
        if let dot = s.firstIndex(of: ".") {
            var end = s.index(after: dot)
            while end < s.endIndex, s[end].isNumber { end = s.index(after: end) }
            s.removeSubrange(dot..<end)
        }
        return iso.date(from: s)
    }
}
