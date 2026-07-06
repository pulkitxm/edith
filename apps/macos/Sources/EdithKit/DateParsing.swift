import Foundation

public enum EdithDate {
    public static func parseISO(_ s: String?) -> Date? {
        guard var s else { return nil }
        s = s.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        return ISO8601DateFormatter().date(from: s)
    }
}
