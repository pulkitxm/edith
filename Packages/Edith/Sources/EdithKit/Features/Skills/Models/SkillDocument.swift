import Foundation

public struct SkillDocument: Sendable, Equatable {
    public let markdown: String
    public let isCached: Bool

    public init(markdown: String, isCached: Bool = false) {
        self.markdown = markdown
        self.isCached = isCached
    }

    public var metadata: String {
        sections?.metadata ?? ""
    }

    public var body: String {
        sections?.body ?? markdown
    }

    private var sections: (metadata: String, body: String)? {
        let lines = markdown.components(separatedBy: .newlines)
        guard lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") else {
            return nil
        }
        return (
            lines[1..<end].joined(separator: "\n"),
            lines.dropFirst(end + 1).joined(separator: "\n").trimmingCharacters(in: .newlines)
        )
    }
}

public actor SkillDocumentStore {
    public static let shared = SkillDocumentStore()
    private let cacheDirectory: URL
    private let fetch: @Sendable (URL) async throws -> Data

    public init(
        cacheDirectory: URL = AppData.supportDir.appendingPathComponent("plugins/cache"),
        fetch: @escaping @Sendable (URL) async throws -> Data = { url in
            let request = URLRequest(
                url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
                throw SkillsError.message("GitHub could not return this skill. Try again shortly.")
            }
            return data
        }
    ) {
        self.cacheDirectory = cacheDirectory
        self.fetch = fetch
    }

    public func load(_ skill: EdithSkill) async throws -> SkillDocument {
        guard EdithSkillLibrary.skills.contains(skill) else {
            throw SkillsError.message("This skill is not in the Edith library.")
        }
        let cached = cacheDirectory.appendingPathComponent(skill.id + ".md")
        do {
            let data = try await fetch(skill.sourceURL)
            try Task.checkCancellation()
            let document = try Self.decode(data, skill: skill, cached: false)
            try? FileManager.default.createDirectory(
                at: cacheDirectory, withIntermediateDirectories: true)
            try? data.write(to: cached, options: .atomic)
            return document
        } catch {
            try Task.checkCancellation()
            if let data = try? Data(contentsOf: cached),
                let document = try? Self.decode(data, skill: skill, cached: true)
            {
                return document
            }
            throw SkillsError.message(
                "Could not load the skill from GitHub. Check your connection and try again.")
        }
    }

    private static func decode(_ data: Data, skill: EdithSkill, cached: Bool) throws
        -> SkillDocument
    {
        guard data.count < 400_000, let markdown = String(data: data, encoding: .utf8) else {
            throw SkillsError.message("The skill is too large or is not valid Markdown text.")
        }
        let document = SkillDocument(markdown: markdown, isCached: cached)
        guard document.metadata.components(separatedBy: .newlines).contains("name: " + skill.id),
            !document.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw SkillsError.message("GitHub returned an invalid skill document.")
        }
        return document
    }
}
