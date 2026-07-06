import Foundation
import Testing

@testable import EdithKit

@Suite struct GHSearchParsingTests {
    private func json(_ prs: [(title: String, repo: String, url: String, state: String?)]) -> Data {
        let array: [[String: Any]] = prs.map { pr in
            var obj: [String: Any] = [
                "title": pr.title, "url": pr.url, "repository": ["nameWithOwner": pr.repo],
            ]
            if let state = pr.state { obj["state"] = state }
            return obj
        }
        return try! JSONSerialization.data(withJSONObject: array)
    }

    @Test func parsesBasicFields() {
        let data = json([("Fix bug", "acme/widgets", "https://x/1", "MERGED")])
        let prs = GHSearchParsing.parse(data)
        #expect(prs.count == 1)
        #expect(prs[0].title == "Fix bug")
        #expect(prs[0].repo == "acme/widgets")
        #expect(prs[0].state == "MERGED")
    }

    @Test func allowlistFiltersByExactRepo() {
        let data = json([
            ("A", "acme/widgets", "https://x/1", nil),
            ("B", "other/thing", "https://x/2", nil),
        ])
        let prs = GHSearchParsing.parse(data, allowlist: ["acme/widgets"])
        #expect(prs.count == 1)
        #expect(prs[0].title == "A")
    }

    @Test func allowlistFiltersByOrgPrefix() {
        let data = json([
            ("A", "acme/widgets", "https://x/1", nil),
            ("B", "other/thing", "https://x/2", nil),
        ])
        let prs = GHSearchParsing.parse(data, allowlist: ["acme"])
        #expect(prs.count == 1)
        #expect(prs[0].repo == "acme/widgets")
    }

    @Test func emptyAllowlistKeepsEverything() {
        let data = json([
            ("A", "acme/widgets", "https://x/1", nil),
            ("B", "other/thing", "https://x/2", nil),
        ])
        #expect(GHSearchParsing.parse(data, allowlist: []).count == 2)
    }

    @Test func linesFormatWithStateSuffix() {
        let prs = [GHSearchParsing.PR(title: "Fix", repo: "a/b", url: "u", state: "MERGED")]
        #expect(GHSearchParsing.lines(prs) == ["- Fix (a/b) [MERGED]"])
    }
}
