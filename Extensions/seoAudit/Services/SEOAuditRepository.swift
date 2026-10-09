import EdithExtensionSupport
import Foundation

struct SEOAuditRepository {
    let root: URL
    private let fileManager: FileManager

    init(
        root: URL = ExtensionData.root.appendingPathComponent("SEOAudit", isDirectory: true),
        fileManager: FileManager = .default
    ) {
        self.root = root
        self.fileManager = fileManager
    }

    func loadSummaries() throws -> [SEOAuditProjectSummary] {
        let file = root.appendingPathComponent("projects.json")
        guard fileManager.fileExists(atPath: file.path) else { return [] }
        return try decoder.decode([SEOAuditProjectSummary].self, from: read(file))
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func loadProject(id: UUID) throws -> SEOAuditProject {
        let file = projectFile(id: id)
        return try decoder.decode(SEOAuditProject.self, from: read(file))
    }

    func save(_ project: SEOAuditProject) throws {
        try validate(root)
        try fileManager.createDirectory(
            at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try SEOAuditOwnedIO.write(
            encoder.encode(project), to: projectFile(id: project.id), root: root)
        var summaries = (try? loadSummaries()) ?? []
        summaries.removeAll { $0.id == project.id }
        summaries.append(SEOAuditProjectSummary(project: project))
        summaries.sort { $0.updatedAt > $1.updatedAt }
        try SEOAuditOwnedIO.write(
            encoder.encode(summaries), to: root.appendingPathComponent("projects.json"), root: root)
    }

    func loadDraft(id: UUID) throws -> SEOAuditDraft {
        let file = draftFile(id: id)
        guard fileManager.fileExists(atPath: file.path) else { return SEOAuditDraft() }
        return try decoder.decode(SEOAuditDraft.self, from: read(file))
    }

    func saveDraft(id: UUID, _ draft: SEOAuditDraft) throws {
        try validate(root)
        try fileManager.createDirectory(
            at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try SEOAuditOwnedIO.write(encoder.encode(draft), to: draftFile(id: id), root: root)
    }

    func delete(id: UUID) throws {
        try validate(root)
        try validate(projectAssetsDirectory(id: id).deletingLastPathComponent())
        let assets = projectAssetsDirectory(id: id)
        if fileManager.fileExists(atPath: assets.path) { try fileManager.removeItem(at: assets) }
        let file = projectFile(id: id)
        if fileManager.fileExists(atPath: file.path) { try fileManager.removeItem(at: file) }
        let draft = draftFile(id: id)
        if fileManager.fileExists(atPath: draft.path) { try fileManager.removeItem(at: draft) }
        var summaries = (try? loadSummaries()) ?? []
        summaries.removeAll { $0.id == id }
        try fileManager.createDirectory(
            at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try SEOAuditOwnedIO.write(
            encoder.encode(summaries), to: root.appendingPathComponent("projects.json"), root: root)
    }

    private func validate(_ directory: URL) throws {
        guard SEOAuditOwnedIO.safeParents(directory, root: root) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
    }

    private func read(_ file: URL) throws -> Data {
        guard let data = SEOAuditOwnedIO.read(file, root: root) else {
            throw CocoaError(.fileReadTooLarge)
        }
        return data
    }

    private func projectFile(id: UUID) -> URL {
        root.appendingPathComponent("project-\(id.uuidString.lowercased()).json")
    }

    private func draftFile(id: UUID) -> URL {
        root.appendingPathComponent("draft-\(id.uuidString.lowercased()).json")
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
