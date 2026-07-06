import Foundation

public enum GHSearchParsing {
    public struct PR: Equatable {
        public let title: String
        public let repo: String
        public let url: String
        public let state: String?
    }

    public static func parse(_ data: Data, allowlist: [String] = []) -> [PR] {
        guard let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        return array.compactMap { obj -> PR? in
            guard let title = obj["title"] as? String, let url = obj["url"] as? String else {
                return nil
            }
            let repo = (obj["repository"] as? [String: Any])?["nameWithOwner"] as? String ?? ""
            guard allowlist.isEmpty || matches(repo, allowlist: allowlist) else { return nil }
            return PR(title: title, repo: repo, url: url, state: obj["state"] as? String)
        }
    }

    public static func lines(_ prs: [PR]) -> [String] {
        prs.map { pr in
            let suffix = pr.state.map { " [\($0)]" } ?? ""
            return "- \(pr.title) (\(pr.repo))\(suffix)"
        }
    }

    private static func matches(_ repo: String, allowlist: [String]) -> Bool {
        allowlist.contains { entry in
            repo == entry || repo.hasPrefix("\(entry)/")
        }
    }
}
