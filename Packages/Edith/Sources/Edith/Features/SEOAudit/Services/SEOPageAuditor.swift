import Foundation

struct SEOPageAuditor: Sendable {
    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func audit(_ url: URL) async -> SEOAuditPageResult {
        let startedAt = ContinuousClock.now
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 45
            request.setValue("Edith SEO Audit", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await session.data(for: request)
            let elapsed = ContinuousClock.now - startedAt
            let milliseconds =
                Int(elapsed.components.seconds * 1_000)
                + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)
            let http = response as? HTTPURLResponse
            let html = String(data: data, encoding: .utf8) ?? ""
            let metadata = HTMLMetadataParser.parse(html, baseURL: url)
            return SEOAuditPageResult(
                url: url.absoluteString, statusCode: http?.statusCode,
                responseMilliseconds: milliseconds, bytes: data.count, metadata: metadata,
                issues: SEOIssueAnalyzer.issues(
                    url: url, statusCode: http?.statusCode, metadata: metadata))
        } catch {
            return SEOAuditPageResult(
                url: url.absoluteString, statusCode: nil, responseMilliseconds: nil, bytes: 0,
                metadata: .empty,
                issues: [
                    SEOAuditIssue(
                        code: "request-failed", severity: .error, title: "Page could not be read",
                        detail: error.localizedDescription)
                ], error: error.localizedDescription)
        }
    }
}

enum HTMLMetadataParser {
    static func parse(_ html: String, baseURL: URL) -> SEOAuditMetadata {
        let metas = tags(named: "meta", in: html).map(attributes)
        let links = tags(named: "link", in: html).map(attributes)
        let htmlTag = tags(named: "html", in: html).first.map(attributes)
        let title = text(in: html, tag: "title")
        let heading = text(in: html, tag: "h1")
        let body = text(in: html, tag: "body") ?? ""
        return SEOAuditMetadata(
            title: title,
            description: metaContent(metas, key: "name", value: "description"),
            canonicalURL: resolved(
                links.first {
                    $0["rel"]?.lowercased().split(separator: " ").contains("canonical") == true
                }?["href"],
                baseURL: baseURL),
            robots: metaContent(metas, key: "name", value: "robots"),
            language: htmlTag?["lang"], heading: heading,
            openGraphTitle: metaContent(metas, key: "property", value: "og:title"),
            openGraphDescription: metaContent(
                metas, key: "property", value: "og:description"),
            openGraphImageURL: resolved(
                metaContent(metas, key: "property", value: "og:image"), baseURL: baseURL),
            openGraphType: metaContent(metas, key: "property", value: "og:type"),
            twitterCard: metaContent(metas, key: "name", value: "twitter:card"),
            wordCount: body.split(whereSeparator: \.isWhitespace).count)
    }

    private static func tags(named name: String, in html: String) -> [String] {
        matches(pattern: "(?is)<\(name)\\b[^>]*>", in: html)
    }

    private static func attributes(_ tag: String) -> [String: String] {
        let pattern = #"([A-Za-z_:][A-Za-z0-9_:.-]*)\s*=\s*(["'])(.*?)\2"#
        let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators])
        let range = NSRange(tag.startIndex..., in: tag)
        var values: [String: String] = [:]
        regex?.enumerateMatches(in: tag, range: range) { match, _, _ in
            guard let match, let keyRange = Range(match.range(at: 1), in: tag),
                let valueRange = Range(match.range(at: 3), in: tag)
            else { return }
            values[String(tag[keyRange]).lowercased()] = decode(String(tag[valueRange]))
        }
        return values
    }

    private static func metaContent(
        _ metas: [[String: String]], key: String, value: String
    ) -> String? {
        metas.first { $0[key]?.caseInsensitiveCompare(value) == .orderedSame }?["content"]
    }

    private static func text(in html: String, tag: String) -> String? {
        guard
            let raw = matches(
                pattern: "(?is)<\(tag)\\b[^>]*>(.*?)</\(tag)\\s*>", in: html,
                capture: 1
            ).first
        else { return nil }
        let withoutTags = raw.replacingOccurrences(
            of: "(?is)<[^>]+>", with: " ", options: .regularExpression)
        let normalized = decode(withoutTags).split(whereSeparator: \.isWhitespace).joined(
            separator: " ")
        return normalized.isEmpty ? nil : normalized
    }

    private static func matches(
        pattern: String, in value: String, capture: Int = 0
    ) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(value.startIndex..., in: value)
        return regex.matches(in: value, range: range).compactMap { match in
            guard capture < match.numberOfRanges,
                let matchRange = Range(match.range(at: capture), in: value)
            else { return nil }
            return String(value[matchRange])
        }
    }

    private static func resolved(_ value: String?, baseURL: URL) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return URL(string: value, relativeTo: baseURL)?.absoluteURL.absoluteString
    }

    private static func decode(_ value: String) -> String {
        value.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
    }
}

enum SEOIssueAnalyzer {
    static func issues(
        url: URL, statusCode: Int?, metadata: SEOAuditMetadata
    ) -> [SEOAuditIssue] {
        var issues: [SEOAuditIssue] = []
        if let statusCode, !(200..<300).contains(statusCode) {
            issues.append(
                issue(
                    "http-status", .error, "Page returned HTTP \(statusCode)",
                    "Search engines may not index this response."))
        }
        if metadata.title == nil {
            issues.append(
                issue(
                    "title-missing", .error, "Title is missing",
                    "Add a unique title that describes this page."))
        } else if let title = metadata.title, !(30...60).contains(title.count) {
            issues.append(
                issue(
                    "title-length", .warning, "Title length is \(title.count) characters",
                    "Aim for 30 to 60 characters."))
        }
        if metadata.description == nil {
            issues.append(
                issue(
                    "description-missing", .warning, "Meta description is missing",
                    "Add a concise summary for search results."))
        } else if let description = metadata.description, !(70...160).contains(description.count) {
            issues.append(
                issue(
                    "description-length", .notice,
                    "Description length is \(description.count) characters",
                    "Aim for 70 to 160 characters."))
        }
        if metadata.canonicalURL == nil {
            issues.append(
                issue(
                    "canonical-missing", .warning, "Canonical URL is missing",
                    "Declare the preferred URL for this page."))
        }
        if metadata.heading == nil {
            issues.append(
                issue("heading-missing", .warning, "H1 is missing", "Add one primary heading."))
        }
        if metadata.language == nil {
            issues.append(
                issue(
                    "language-missing", .notice, "Document language is missing",
                    "Set the lang attribute on the HTML element."))
        }
        if metadata.openGraphTitle == nil || metadata.openGraphDescription == nil {
            issues.append(
                issue(
                    "open-graph-copy", .warning, "Open Graph copy is incomplete",
                    "Set both og:title and og:description."))
        }
        if metadata.openGraphImageURL == nil {
            issues.append(
                issue(
                    "open-graph-image", .warning, "Open Graph image is missing",
                    "Add an og:image for shared links."))
        }
        if metadata.twitterCard == nil {
            issues.append(
                issue(
                    "twitter-card", .notice, "X card type is missing",
                    "Set twitter:card for consistent previews."))
        }
        if url.scheme?.lowercased() != "https", url.host != "localhost", url.host != "127.0.0.1" {
            issues.append(
                issue("https", .error, "Page is not using HTTPS", "Serve public pages over HTTPS."))
        }
        return issues
    }

    private static func issue(
        _ code: String, _ severity: SEOAuditSeverity, _ title: String, _ detail: String
    ) -> SEOAuditIssue {
        SEOAuditIssue(code: code, severity: severity, title: title, detail: detail)
    }
}

extension SEOAuditMetadata {
    static let empty = SEOAuditMetadata(
        title: nil, description: nil, canonicalURL: nil, robots: nil, language: nil,
        heading: nil, openGraphTitle: nil, openGraphDescription: nil,
        openGraphImageURL: nil, openGraphType: nil, twitterCard: nil, wordCount: 0)
}
