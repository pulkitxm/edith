import Foundation

enum SitemapCrawlerError: LocalizedError {
    case invalidResponse(URL)
    case empty(URL)

    var errorDescription: String? {
        switch self {
        case let .invalidResponse(url): "Could not read a sitemap from \(url.absoluteString)."
        case let .empty(url): "The sitemap at \(url.absoluteString) did not contain any pages."
        }
    }
}

struct SitemapCrawler: Sendable {
    let session: SEOAuditHTTPClient
    let maximumPages: Int
    let maximumSitemaps: Int

    init(
        session: SEOAuditHTTPClient = SEOAuditHTTPClient(), maximumPages: Int = 20_000,
        maximumSitemaps: Int = 1_000
    ) {
        self.session = session
        self.maximumPages = maximumPages
        self.maximumSitemaps = maximumSitemaps
    }

    func pages(startingAt input: URL) async throws -> [URL] {
        var candidates: [URL] = []
        if input.pathExtension.lowercased() == "xml" { candidates.append(input) }
        candidates.append(contentsOf: try await robotsSitemaps(for: input))
        if let origin = originURL(for: input) {
            candidates.append(origin.appendingPathComponent("sitemap.xml"))
        }
        var visited = Set<URL>()
        for candidate in unique(candidates) {
            try Task.checkCancellation()
            do {
                let pages = try await crawl(candidate, visited: &visited)
                if !pages.isEmpty { return Array(unique(pages).prefix(maximumPages)) }
            } catch {
                try Task.checkCancellation()
                continue
            }
        }
        if input.pathExtension.lowercased() == "xml" { throw SitemapCrawlerError.empty(input) }
        return [input]
    }

    private func crawl(_ sitemap: URL, visited: inout Set<URL>) async throws -> [URL] {
        guard visited.count < maximumSitemaps, visited.insert(sitemap).inserted else { return [] }
        let data = try await fetch(sitemap)
        let document = try SitemapDocument.parse(data, maximumLocations: maximumPages)
        if !document.isIndex { return document.locations }
        var pages: [URL] = []
        for child in document.locations where pages.count < maximumPages {
            try Task.checkCancellation()
            if let childPages = try? await crawl(child, visited: &visited) {
                pages.append(contentsOf: childPages)
            }
        }
        return unique(pages)
    }

    private func robotsSitemaps(for input: URL) async throws -> [URL] {
        guard let origin = originURL(for: input) else { return [] }
        let robots = origin.appendingPathComponent("robots.txt")
        guard let data = try? await fetch(robots), let text = String(data: data, encoding: .utf8)
        else { return [] }
        return text.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2,
                parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "sitemap"
            else { return nil }
            return URL(string: parts[1].trimmingCharacters(in: .whitespaces))
        }
    }

    private func originURL(for input: URL) -> URL? {
        guard let scheme = input.scheme, let host = input.host else { return nil }
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.port = input.port
        components.path = "/"
        return components.url
    }

    private func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("Edith SEO Audit", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request, maximumBytes: 8 * 1_024 * 1_024)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode)
        else { throw SitemapCrawlerError.invalidResponse(url) }
        return data
    }

    private func unique(_ values: [URL]) -> [URL] {
        var seen = Set<String>()
        return values.filter { seen.insert($0.absoluteString).inserted }
    }
}

private final class SitemapDocument: NSObject, XMLParserDelegate {
    var locations: [URL] = []
    var isIndex = false
    private var currentElement = ""
    private var text = ""
    private var oversized = false
    private var maximumLocations = 20_000

    static func parse(_ data: Data, maximumLocations: Int) throws -> SitemapDocument {
        let document = SitemapDocument()
        document.maximumLocations = max(0, min(20_000, maximumLocations))
        let parser = XMLParser(data: data)
        parser.delegate = document
        guard parser.parse() else {
            throw parser.parserError
                ?? SitemapCrawlerError.invalidResponse(
                    URL(string: "about:blank")!)
        }
        return document
    }

    func parser(
        _: XMLParser, didStartElement elementName: String, namespaceURI _: String?,
        qualifiedName _: String?, attributes _: [String: String] = [:]
    ) {
        currentElement = elementName.lowercased()
        if currentElement == "sitemapindex" { isIndex = true }
        if currentElement == "loc" { text = ""; oversized = false }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if Task.isCancelled { parser.abortParsing(); return }
        guard currentElement == "loc", !oversized else { return }
        guard string.utf8.count <= 4_096 - text.utf8.count else {
            oversized = true; text = ""; return
        }
        text += string
    }

    func parser(
        _: XMLParser, didEndElement elementName: String, namespaceURI _: String?,
        qualifiedName _: String?
    ) {
        if elementName.lowercased() == "loc", !oversized, locations.count < maximumLocations,
            let url = SEOAuditURLInput.normalize(text)
        {
            locations.append(url)
        }
        currentElement = ""
    }
}
