import Foundation

public enum CommandBarFileSearchSupport {
    public static let shortestQuery = 2
    public static let candidateLimit = 1_000
    public static let resultLimit = 200
    public static let ignoredNames = [
        "node_modules", ".git", "DerivedData", "Pods", ".build", "vendor",
    ]

    public static func expression(for query: String) -> String? {
        let clean = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = clean.split(whereSeparator: \.isWhitespace).map(String.init)
        guard clean.count >= shortestQuery, !words.isEmpty else { return nil }
        return words.map { "kMDItemFSName == \"*\(escaped($0))*\"cd" }
            .joined(separator: " && ")
    }

    public static func escaped(_ value: String) -> String {
        var result = ""
        for character in value {
            if ["\\", "\"", "*", "?"].contains(character) { result.append("\\") }
            result.append(character)
        }
        return result
    }

    public static func resolvedScopes(
        _ saved: [String], homeDirectory: String,
        isSearchableDirectory: (String) -> Bool
    ) -> [String] {
        let home = standardized(homeDirectory)
        var seen = Set<String>()
        var result: [String] = []
        for raw in saved {
            let expanded: String
            if raw == "~" {
                expanded = home
            } else if raw.hasPrefix("~/") {
                expanded = home + raw.dropFirst()
            } else {
                expanded = raw
            }
            let path = standardized(expanded)
            if !path.isEmpty, isSearchableDirectory(path), seen.insert(path).inserted {
                result.append(path)
            }
        }
        return result
    }

    public static func isOfferable(path: String, isPackage: (String) -> Bool) -> Bool {
        let value = standardized(path)
        let components = value.split(separator: "/").map(String.init)
        guard let last = components.last, !last.hasPrefix(".") else { return false }
        var ancestor = ""
        for component in components.dropLast() {
            if component.hasPrefix(".") { return false }
            ancestor += "/" + component
            if isPackage(ancestor) { return false }
        }
        return true
    }

    public static func isIgnored(path: String, names: [String] = ignoredNames) -> Bool {
        let components = path.split(separator: "/").map { $0.lowercased() }
        return names.contains { name in
            let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !wanted.isEmpty else { return false }
            if components.contains(wanted) { return true }
            guard let last = components.last else { return false }
            if wanted.hasPrefix("*.") { return last.hasSuffix(String(wanted.dropFirst())) }
            return wanted.hasPrefix(".") && last != wanted && last.hasSuffix(wanted)
        }
    }

    public static func offerable(
        paths: [String], ignored: [String] = ignoredNames,
        isPackage: (String) -> Bool
    ) -> [String] {
        var packageCache: [String: Bool] = [:]
        var seen = Set<String>()
        var result: [String] = []
        for path in paths {
            let package: (String) -> Bool = { candidate in
                if let cached = packageCache[candidate] { return cached }
                let value = isPackage(candidate)
                packageCache[candidate] = value
                return value
            }
            guard isOfferable(path: path, isPackage: package),
                !isIgnored(path: path, names: ignored), seen.insert(path).inserted
            else { continue }
            result.append(path)
            if result.count == resultLimit { break }
        }
        return result
    }

    public static func abbreviating(_ path: String, homeDirectory: String) -> String {
        let home = standardized(homeDirectory)
        guard path == home || path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }

    private static func standardized(_ path: String) -> String {
        var result = (path as NSString).standardizingPath
        while result.count > 1, result.hasSuffix("/") { result.removeLast() }
        return result
    }
}
