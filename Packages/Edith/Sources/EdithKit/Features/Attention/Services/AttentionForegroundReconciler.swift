import Foundation

public enum AttentionBrowserIdentity {
    public static let bundleIDs: Set<String> = [
        "com.apple.safari",
        "com.apple.safaritechnologypreview",
        "com.brave.browser",
        "com.brave.browser.beta",
        "com.brave.browser.nightly",
        "com.google.chrome",
        "com.google.chrome.beta",
        "com.google.chrome.canary",
        "com.google.chrome.dev",
        "com.microsoft.edgemac",
        "com.microsoft.edgemac.beta",
        "com.microsoft.edgemac.dev",
        "com.operasoftware.opera",
        "com.operasoftware.operadeveloper",
        "com.operasoftware.operagx",
        "com.pushplaylabs.sidekick",
        "com.sigmaos.sigmaos.macos",
        "com.vivaldi.vivaldi",
        "company.thebrowser.browser",
        "company.thebrowser.dia",
        "org.chromium.chromium",
        "org.mozilla.firefox",
        "org.mozilla.firefoxdeveloperedition",
        "org.mozilla.nightly",
    ]

    public static func isBrowser(bundleID: String?, appName: String?) -> Bool {
        if let bundleID, bundleIDs.contains(bundleID.lowercased()) { return true }
        guard let appName else { return false }
        let name = appName.lowercased()
        return ["chrome", "chromium", "safari", "firefox", "edge", "opera", "brave", "vivaldi"]
            .contains { name.contains($0) }
    }
}

public enum AttentionTitleCorrelation {
    public static let minimumOverlap = 6
    public static let minimumRatio = 0.25

    public static func normalized(_ value: String?) -> String {
        guard let value else { return "" }
        var scalars = String.UnicodeScalarView()
        var pendingSpace = false
        for scalar in value.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                if pendingSpace, !scalars.isEmpty { scalars.append(" ") }
                pendingSpace = false
                scalars.append(scalar)
            } else {
                pendingSpace = true
            }
        }
        return String(scalars)
    }

    public static func overlap(_ window: String, _ page: String) -> Int {
        guard !window.isEmpty, !page.isEmpty else { return 0 }
        if window.contains(page) { return page.utf8.count }
        if page.contains(window) { return window.utf8.count }
        let left = Array(window.utf8)
        let right = Array(page.utf8)
        var previous = [Int](repeating: 0, count: right.count + 1)
        var current = previous
        var best = 0
        for index in 1...left.count {
            let character = left[index - 1]
            for position in 1...right.count {
                if character == right[position - 1] {
                    current[position] = previous[position - 1] + 1
                    best = max(best, current[position])
                } else {
                    current[position] = 0
                }
            }
            swap(&previous, &current)
        }
        return best
    }

    public static func corroborates(window: String, page: String) -> Bool {
        corroborates(shared: overlap(window, page), window: window, page: page)
    }

    public static func corroborates(shared: Int, window: String, page: String) -> Bool {
        guard shared >= minimumOverlap else { return false }
        return Double(shared) >= minimumRatio * Double(min(window.count, page.count))
    }
}
