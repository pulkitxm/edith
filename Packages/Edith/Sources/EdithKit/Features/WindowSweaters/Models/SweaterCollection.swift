import Foundation

public struct SweaterAppRule: Equatable, Sendable {
    public let match: String
    public let color: UInt32
    public let chart: String

    public init(match: String, color: UInt32, chart: String) {
        self.match = match
        self.color = color
        self.chart = chart
    }
}

public enum SweaterCollection {
    public static func rule(for appName: String, userRules: [SweaterAppRule] = []) -> SweaterAppRule?
    {
        guard !appName.isEmpty else { return nil }
        if let match = longestPrefixMatch(appName, in: userRules) { return match }
        return longestPrefixMatch(appName, in: builtIn)
    }

    public static func chartName(for appName: String, userRules: [SweaterAppRule] = []) -> String? {
        guard let rule = rule(for: appName, userRules: userRules), !rule.chart.isEmpty
        else { return nil }
        return rule.chart
    }

    public static func appName(fromExecutablePath path: String) -> String? {
        let marker = ".app/Contents/MacOS/"
        guard let range = path.range(of: marker), range.upperBound < path.endIndex
        else { return nil }
        let leading = path[path.startIndex..<range.lowerBound]
        guard let separator = leading.lastIndex(of: "/") else {
            return leading.isEmpty ? nil : String(leading)
        }
        let name = leading[leading.index(after: separator)...]
        return name.isEmpty ? nil : String(name)
    }

    private static func longestPrefixMatch(_ appName: String, in rules: [SweaterAppRule])
        -> SweaterAppRule?
    {
        var best: SweaterAppRule?
        var bestLength = 0
        let folded = appName.lowercased()
        for rule in rules where !rule.match.isEmpty {
            let candidate = rule.match.lowercased()
            guard candidate.count > bestLength, folded.hasPrefix(candidate) else { continue }
            best = rule
            bestLength = candidate.count
        }
        return best
    }
}
