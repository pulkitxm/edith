import Foundation

public enum BrowserSearchEngine: String, CaseIterable, Sendable {
    case google, duckDuckGo, bing, kagi

    public static let fallback = BrowserSearchEngine.google

    public var title: String {
        switch self {
        case .google: "Google"
        case .duckDuckGo: "DuckDuckGo"
        case .bing: "Bing"
        case .kagi: "Kagi"
        }
    }

    public var home: URL {
        switch self {
        case .google: URL(string: "https://www.google.com/")!
        case .duckDuckGo: URL(string: "https://duckduckgo.com/")!
        case .bing: URL(string: "https://www.bing.com/")!
        case .kagi: URL(string: "https://kagi.com/")!
        }
    }

    public func searchURL(for query: String) -> URL? {
        var components = URLComponents(url: home, resolvingAgainstBaseURL: false)
        components?.path = self == .duckDuckGo ? "/" : "/search"
        components?.queryItems = [URLQueryItem(name: "q", value: query)]
        return components?.url
    }
}
