import EdithExtensionSupport
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

@MainActor public final class SkillDocumentStore {
    public private(set) var isStopped = false
    private var pending: [UUID: Task<SkillDocument, any Error>] = [:]
    private var documents: [String: SkillDocument] = [:]
    private let cacheDirectory: URL
    private let fetch: @Sendable (URL) async throws -> Data

    public init(
        cacheDirectory: URL = ExtensionData.root.appendingPathComponent("cache"),
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

    public func cachedDocument(for skill: EdithSkill) -> SkillDocument? {
        documents[skill.id].map { SkillDocument(markdown: $0.markdown, isCached: true) }
    }

    public func load(_ skill: EdithSkill) async throws -> SkillDocument {
        try Task.checkCancellation()
        guard !isStopped, EdithSkillLibrary.skills.contains(skill) else {
            throw SkillsError.message("This skill is not in the Edith library.")
        }
        let document: SkillDocument
        do {
            let token = UUID()
            let cache = cacheDirectory
            let fetch = fetch
            let task = Task {
                try await Self.loadDocument(skill, cacheDirectory: cache, fetch: fetch)
            }
            pending[token] = task
            defer { pending[token] = nil }
            document = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
        } catch {
            try Task.checkCancellation()
            guard !isStopped, let previous = documents[skill.id] else { throw error }
            document = SkillDocument(markdown: previous.markdown, isCached: true)
        }
        try Task.checkCancellation()
        guard !isStopped else { throw CancellationError() }
        documents[skill.id] = document
        return document
    }

    public func recordInstalled(_ document: SkillDocument, for skill: EdithSkill) throws {
        try Task.checkCancellation()
        guard !isStopped else { throw CancellationError() }
        let data = Data(document.markdown.utf8)
        let document = try Self.decode(data, skill: skill, cached: false)
        guard EdithSkillLibrary.skills.contains(skill) else {
            throw SkillsError.message("This skill is not in the Edith library.")
        }
        documents[skill.id] = document
        try? FileManager.default.createDirectory(
            at: cacheDirectory, withIntermediateDirectories: true)
        try? data.write(
            to: cacheDirectory.appendingPathComponent(skill.id + ".md"), options: .atomic)
    }

    nonisolated private static func loadDocument(
        _ skill: EdithSkill, cacheDirectory: URL,
        fetch: @Sendable (URL) async throws -> Data
    ) async throws -> SkillDocument {
        let cached = cacheDirectory.appendingPathComponent(skill.id + ".md")
        do {
            let data = try await fetch(skill.sourceURL)
            try Task.checkCancellation()
            let document = try Self.decode(data, skill: skill, cached: false)
            try? FileManager.default.createDirectory(
                at: cacheDirectory, withIntermediateDirectories: true)
            try Task.checkCancellation()
            try? data.write(to: cached, options: .atomic)
            return document
        } catch {
            try Task.checkCancellation()
            if let handle = try? FileHandle(forReadingFrom: cached),
                let data = try? readCache(handle),
                let document = try? Self.decode(data, skill: skill, cached: true)
            {
                return document
            }
            throw SkillsError.message(
                "Could not load the skill from GitHub. Check your connection and try again.")
        }
    }

    public func shutdown() async {
        isStopped = true
        let tasks = Array(pending.values)
        for task in tasks { task.cancel() }
        for task in tasks { _ = await task.result }
        pending.removeAll()
        documents.removeAll()
    }

    nonisolated private static func readCache(_ handle: FileHandle) throws -> Data {
        defer { try? handle.close() }
        return try handle.read(upToCount: 400_000) ?? Data()
    }

    nonisolated static func decode(_ data: Data, skill: EdithSkill, cached: Bool) throws
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
