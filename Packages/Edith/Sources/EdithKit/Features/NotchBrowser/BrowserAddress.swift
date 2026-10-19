import EdithKit
import Foundation

enum BrowserAddress {
    private static let allowedSchemes: Set<String> = ["http", "https", "about", "file", "data"]

    static func url(for input: String, engine: BrowserSearchEngine) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let direct = directURL(text) { return direct }
        return engine.searchURL(for: text)
    }

    static func directURL(_ text: String) -> URL? {
        guard !text.contains(" ") else { return nil }
        if let url = URL(string: text), let scheme = url.scheme?.lowercased(),
            allowedSchemes.contains(scheme), !["http", "https"].contains(scheme) || url.host != nil
        {
            return url
        }
        guard looksLikeHost(text) else { return nil }
        let scheme = isLocal(text) ? "http" : "https"
        return URL(string: "\(scheme)://\(text)")
    }

    static func displayText(for url: URL?) -> String {
        guard let url else { return "" }
        if url.absoluteString == "about:blank" { return "" }
        return url.absoluteString
    }

    private static func looksLikeHost(_ text: String) -> Bool {
        let host =
            text.split(separator: "/", maxSplits: 1).first.map(String.init)?
            .split(separator: ":", maxSplits: 1).first.map(String.init) ?? ""
        guard !host.isEmpty else { return false }
        if host == "localhost" { return true }
        if host.split(separator: ".").count == 4, host.allSatisfy({ $0.isNumber || $0 == "." }) {
            return true
        }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.allSatisfy({ !$0.isEmpty }),
            let tld = labels.last, tld.count >= 2, tld.allSatisfy(\.isLetter)
        else { return false }
        return host.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." }
    }

    private static func isLocal(_ text: String) -> Bool {
        text.hasPrefix("localhost") || text.hasPrefix("127.") || text.hasPrefix("0.0.0.0")
    }
}
