import Foundation

public struct CatalogSkill: Codable, Identifiable, Equatable, Sendable {
    public let source: String
    public let skillId: String
    public let name: String
    public let installs: Int
    public var id: String { source + "/" + skillId }
    public var website: URL {
        URL(string: "https://skills.sh")!.appendingPathComponent(id)
    }

    public init(source: String, skillId: String, name: String, installs: Int) {
        self.source = source
        self.skillId = skillId
        self.name = name
        self.installs = installs
    }
}

public struct SkillCatalogPage: Decodable, Sendable {
    public let skills: [CatalogSkill]
    public let total: Int?
    public let hasMore: Bool?

    public init(skills: [CatalogSkill], total: Int? = nil, hasMore: Bool? = nil) {
        self.skills = skills
        self.total = total
        self.hasMore = hasMore
    }
}

public enum SkillRanking: String, CaseIterable, Identifiable, Sendable {
    case allTime = "all-time"
    case trending
    case hot

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .allTime: "All time"
        case .trending: "Trending"
        case .hot: "Hot"
        }
    }
}

public enum SkillCatalogClient {
    public static func url(query: String, ranking: SkillRanking, page: Int) -> URL {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.count >= 2 {
            var components = URLComponents(string: "https://skills.sh/api/search")!
            components.queryItems = [
                URLQueryItem(name: "q", value: query), URLQueryItem(name: "limit", value: "100"),
            ]
            return components.url!
        }
        return URL(string: "https://skills.sh/api/skills/\(ranking.rawValue)/\(max(0, page))")!
    }

    public static func fetch(query: String, ranking: SkillRanking, page: Int) async throws
        -> SkillCatalogPage
    {
        var request = URLRequest(url: url(query: query, ranking: ranking, page: page))
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            throw SkillsError.message("skills.sh is unavailable. Try again shortly.")
        }
        return try JSONDecoder().decode(SkillCatalogPage.self, from: data)
    }
}

public enum SkillsError: LocalizedError {
    case message(String)

    public var errorDescription: String? {
        switch self {
        case .message(let message): message
        }
    }
}
