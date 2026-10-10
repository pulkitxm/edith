import Foundation

public enum SurfaceClockRules {
    public static let maxZones = 12
    public static let zoneSuggestions = [
        "Europe/London", "Europe/Berlin", "Asia/Kolkata", "Asia/Tokyo", "Asia/Singapore",
        "Australia/Sydney", "America/Chicago", "America/Sao_Paulo", "Asia/Dubai",
    ]

    public static func zones(_ raw: String) -> [String] {
        guard raw.utf8.count <= 4096 else { return [] }
        var seen = Set<String>()
        return Array(
            raw.split(separator: ",").map(String.init).filter {
                TimeZone(identifier: $0) != nil && seen.insert($0).inserted
            }.prefix(maxZones))
    }

    public static func add(_ id: String, to raw: String) -> String {
        let current = zones(raw)
        guard current.count < maxZones, !current.contains(id), TimeZone(identifier: id) != nil
        else { return raw }
        return (current + [id]).joined(separator: ",")
    }

    public static func cityName(_ id: String) -> String {
        (id.split(separator: "/").last.map(String.init) ?? id)
            .replacingOccurrences(of: "_", with: " ")
    }

    public static func offsetLabel(seconds: Int) -> String {
        if seconds == 0 { return "same time" }
        let hours = Double(seconds) / 3600
        return hours == hours.rounded()
            ? String(format: "%+.0fh", hours) : String(format: "%+.1fh", hours)
    }

    public static func zoneMatches(query: String, taken: Set<String>) -> [String] {
        guard query.utf8.count <= 256 else { return [] }
        if query.isEmpty { return zoneSuggestions.filter { !taken.contains($0) } }
        let needle = query.replacingOccurrences(of: " ", with: "_")
        return Set(TimeZone.knownTimeZoneIdentifiers).union(zoneSuggestions).sorted()
            .filter { !taken.contains($0) && $0.localizedCaseInsensitiveContains(needle) }
            .prefix(14).map { $0 }
    }
}
