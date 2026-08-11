import EdithCore
import Foundation

public struct Contributor: Codable, Equatable, Sendable, Identifiable {
    public let id: Int
    public let login: String
    public let avatarURL: URL
    public let profileURL: URL
    public let contributions: Int

    public init(id: Int, login: String, avatarURL: URL, profileURL: URL, contributions: Int) {
        self.id = id
        self.login = login
        self.avatarURL = avatarURL
        self.profileURL = profileURL
        self.contributions = contributions
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case login
        case avatarURL = "avatar_url"
        case profileURL = "html_url"
        case contributions
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        login = try container.decode(String.self, forKey: .login)
        avatarURL = try container.decode(URL.self, forKey: .avatarURL)
        profileURL = try container.decode(URL.self, forKey: .profileURL)
        contributions = try container.decodeIfPresent(Int.self, forKey: .contributions) ?? 0
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(login, forKey: .login)
        try container.encode(avatarURL, forKey: .avatarURL)
        try container.encode(profileURL, forKey: .profileURL)
        try container.encode(contributions, forKey: .contributions)
    }

    public var isBot: Bool { login.hasSuffix("[bot]") }
}

public enum Contributors {
    public static let endpoint = URL(
        string: "https://api.github.com/repos/pulkitxm/edith/contributors?per_page=100")!

    public static let refreshInterval: TimeInterval = 60 * 60 * 24

    public static func people(from data: Data) throws -> [Contributor] {
        try JSONDecoder().decode([Contributor].self, from: data)
            .filter { !$0.isBot }
            .sorted { $0.contributions > $1.contributions }
    }

    public static func cached(
        directories: AppDirectories = .current,
        fileManager: FileManager = .default
    ) -> [Contributor] {
        let file = cacheFile(directories)
        guard let data = fileManager.contents(atPath: file.path) else { return [] }
        return (try? JSONDecoder().decode([Contributor].self, from: data)) ?? []
    }

    public static func load(
        directories: AppDirectories = .current,
        fileManager: FileManager = .default,
        session: URLSession = .shared
    ) async -> [Contributor] {
        let file = cacheFile(directories)
        if isFresh(file, fileManager: fileManager) {
            let people = cached(directories: directories, fileManager: fileManager)
            if !people.isEmpty { return people }
        }
        guard let fresh = try? await fetch(session: session) else {
            return cached(directories: directories, fileManager: fileManager)
        }
        store(fresh, at: file, fileManager: fileManager)
        return fresh
    }

    private static func fetch(session: URLSession) async throws -> [Contributor] {
        var request = URLRequest(url: endpoint)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try people(from: data)
    }

    private static func cacheFile(_ directories: AppDirectories) -> URL {
        directories.cache.appendingPathComponent("contributors.json")
    }

    private static func isFresh(_ file: URL, fileManager: FileManager) -> Bool {
        guard
            let modified = try? fileManager.attributesOfItem(atPath: file.path)[.modificationDate]
                as? Date
        else { return false }
        return Date().timeIntervalSince(modified) < refreshInterval
    }

    private static func store(_ people: [Contributor], at file: URL, fileManager: FileManager) {
        guard let data = try? JSONEncoder().encode(people) else { return }
        try? fileManager.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }
}
