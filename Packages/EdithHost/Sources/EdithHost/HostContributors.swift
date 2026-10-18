import EdithHostCore
import Foundation

struct HostContributor: Codable, Equatable, Sendable, Identifiable {
    let id: Int
    let login: String
    let avatarURL: URL
    let profileURL: URL
    let contributions: Int

    enum CodingKeys: String, CodingKey {
        case id, login, contributions
        case avatarURL = "avatar_url"
        case profileURL = "html_url"
    }
}

enum HostContributors {
    struct CacheSnapshot: Sendable {
        let people: [HostContributor]
        let modificationDate: Date?
    }
    static let byteLimit = 262144
    static let endpoint = URL(
        string: "https://api.github.com/repos/pulkitxm/edith/contributors?per_page=100")!

    static func people(from data: Data) throws -> [HostContributor] {
        guard data.count <= byteLimit else { throw URLError(.dataLengthExceedsMaximum) }
        let people = try JSONDecoder().decode([HostContributor].self, from: data)
        guard people.count <= 100, Set(people.map(\.id)).count == people.count,
            people.allSatisfy({
                $0.id > 0 && !$0.login.isEmpty && $0.login.utf8.count <= 100
                    && $0.contributions >= 0 && $0.profileURL.scheme == "https"
                    && $0.profileURL.host == "github.com" && $0.profileURL.user == nil
                    && $0.profileURL.password == nil && $0.avatarURL.scheme == "https"
                    && $0.avatarURL.host == "avatars.githubusercontent.com"
                    && $0.avatarURL.user == nil && $0.avatarURL.password == nil
            })
        else { throw URLError(.cannotParseResponse) }
        return people.filter { !$0.login.hasSuffix("[bot]") }.sorted {
            $0.contributions == $1.contributions
                ? $0.login < $1.login : $0.contributions > $1.contributions
        }
    }
    static func cacheSnapshot(identity: HostIdentity) -> CacheSnapshot {
        let file = cacheFile(identity)
        let manager = FileManager.default
        let attributes = try? manager.attributesOfItem(atPath: file.path)
        let bytes = (attributes?[.size] as? NSNumber)?.intValue ?? Int.max
        let cached =
            bytes <= byteLimit
            ? (try? Data(contentsOf: file)).flatMap { try? people(from: $0) } : nil
        return CacheSnapshot(
            people: cached ?? [], modificationDate: attributes?[.modificationDate] as? Date)
    }
    static func load(
        identity: HostIdentity, session: URLSession = .shared, cacheSnapshot: CacheSnapshot
    ) async -> [HostContributor] {
        if let modified = cacheSnapshot.modificationDate,
            Date().timeIntervalSince(modified) < 86400, !cacheSnapshot.people.isEmpty
        {
            return cacheSnapshot.people
        }
        do {
            var request = URLRequest(url: endpoint)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 10
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                response.expectedContentLength <= Int64(byteLimit)
            else { throw URLError(.badServerResponse) }
            var data = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < byteLimit else { throw URLError(.dataLengthExceedsMaximum) }
                data.append(byte)
            }
            let fresh = try people(from: data)
            try Task.checkCancellation()
            let file = cacheFile(identity)
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(fresh).write(to: file, options: .atomic)
            return fresh
        } catch { return cacheSnapshot.people }
    }
    private static func cacheFile(_ identity: HostIdentity) -> URL {
        identity.root.appendingPathComponent("Caches", isDirectory: true).appendingPathComponent(
            "contributors.json")
    }
}
