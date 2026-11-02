import Foundation

public enum CleanerAge: String, CaseIterable, Codable, Sendable {
    case any, hour, day, week, month, quarter

    public var seconds: TimeInterval? {
        switch self {
        case .any: nil
        case .hour: 3_600
        case .day: 86_400
        case .week: 604_800
        case .month: 2_592_000
        case .quarter: 7_776_000
        }
    }

    public var label: String {
        switch self {
        case .any: "Any"
        case .hour: "1h"
        case .day: "1d"
        case .week: "1w"
        case .month: "1mo"
        case .quarter: "3mo"
        }
    }

    public static func parse(_ text: String) -> TimeInterval? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
        let units: [(String, TimeInterval)] = [
            ("mo", 2_592_000), ("m", 60), ("h", 3_600), ("d", 86_400), ("w", 604_800),
            ("y", 31_536_000),
        ]
        for (suffix, scale) in units where trimmed.hasSuffix(suffix) {
            guard let value = Double(trimmed.dropLast(suffix.count)), value >= 0 else {
                return nil
            }
            return value * scale
        }
        return nil
    }
}

public enum CleanerSort: String, CaseIterable, Codable, Sendable {
    case size, oldest

    public var label: String { self == .size ? "Largest" : "Oldest" }
}

public struct CleanerFilters: Codable, Equatable, Sendable {
    public var minimumAge: TimeInterval?
    public var protectDirty: Bool
    public var sort: CleanerSort

    public init(
        minimumAge: TimeInterval? = nil, protectDirty: Bool = true, sort: CleanerSort = .size
    ) {
        self.minimumAge = minimumAge
        self.protectDirty = protectDirty
        self.sort = sort
    }

    public func admits(_ item: JunkItem, now: Date) -> Bool {
        if protectDirty, item.worktree?.dirty == true { return false }
        guard let minimumAge, let modified = item.lastModified else { return true }
        return now.timeIntervalSince(modified) >= minimumAge
    }

    public func apply(_ categories: [JunkCategory], now: Date) -> [JunkCategory] {
        categories.compactMap { category in
            var visible = category
            visible.items = category.items.filter { admits($0, now: now) }
            if sort == .oldest {
                visible.items.sort {
                    ($0.lastModified ?? .distantFuture) < ($1.lastModified ?? .distantFuture)
                }
            }
            return visible.items.isEmpty ? nil : visible
        }
    }
}

public enum CleanerAgeText {
    public static func since(_ date: Date?, now: Date) -> String? {
        guard let date else { return nil }
        let seconds = max(0, now.timeIntervalSince(date))
        let steps: [(TimeInterval, String)] = [
            (31_536_000, "y"), (2_592_000, "mo"), (604_800, "w"), (86_400, "d"), (3_600, "h"),
            (60, "m"),
        ]
        for (scale, unit) in steps where seconds >= scale {
            return "\(Int(seconds / scale))\(unit) ago"
        }
        return "just now"
    }
}
