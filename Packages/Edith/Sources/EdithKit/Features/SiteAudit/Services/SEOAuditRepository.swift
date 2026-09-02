import Foundation

public struct SEOAuditRepository {
    public let root: URL
    private let fileManager: FileManager

    public init(
        root: URL = AppData.supportDir.appendingPathComponent(
            "SEOAudit", isDirectory: true),
        fileManager: FileManager = .default
    ) {
        self.root = root
        self.fileManager = fileManager
    }

    public func loadSummaries() throws -> [SEOAuditProjectSummary] {
        let file = root.appendingPathComponent("projects.json")
        guard fileManager.fileExists(atPath: file.path) else { return [] }
        return try decoder.decode([SEOAuditProjectSummary].self, from: Data(contentsOf: file))
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    public func loadProject(id: UUID) throws -> SEOAuditProject {
        let file = projectFile(id: id)
        return try decoder.decode(SEOAuditProject.self, from: Data(contentsOf: file))
    }

    public func save(_ project: SEOAuditProject) throws {
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try encoder.encode(project).write(to: projectFile(id: project.id), options: .atomic)
        var summaries = (try? loadSummaries()) ?? []
        summaries.removeAll { $0.id == project.id }
        summaries.append(SEOAuditProjectSummary(project: project))
        summaries.sort { $0.updatedAt > $1.updatedAt }
        try encoder.encode(summaries).write(
            to: root.appendingPathComponent("projects.json"), options: .atomic)
    }

    public func delete(id: UUID) throws {
        let assets = projectAssetsDirectory(id: id)
        if fileManager.fileExists(atPath: assets.path) { try fileManager.removeItem(at: assets) }
        let file = projectFile(id: id)
        if fileManager.fileExists(atPath: file.path) { try fileManager.removeItem(at: file) }
        var summaries = (try? loadSummaries()) ?? []
        summaries.removeAll { $0.id == id }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try encoder.encode(summaries).write(
            to: root.appendingPathComponent("projects.json"), options: .atomic)
    }

    private func projectFile(id: UUID) -> URL {
        root.appendingPathComponent("project-\(id.uuidString.lowercased()).json")
    }

    private func projectAssetsDirectory(id: UUID) -> URL {
        root.appendingPathComponent("assets", isDirectory: true)
            .appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
    }

    private var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
