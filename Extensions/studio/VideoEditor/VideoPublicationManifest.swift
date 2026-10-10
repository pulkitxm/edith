import CoreFoundation
import Darwin
import Foundation

public struct VideoPublicationManifest: Codable, Sendable {
    public let version: Int
    public let items: [Item]

    public struct Item: Codable, Sendable {
        public let projectID: String
        public let projectPath: String
        public let title: String

        public init(projectID: String, projectPath: String, title: String) {
            self.projectID = projectID
            self.projectPath = projectPath
            self.title = title
        }
    }

    public init(version: Int = 1, items: [Item]) {
        self.version = version
        self.items = items
    }
}

public struct VideoPublicationPlan: Codable, Sendable {
    public let version: Int
    public let projects: [Project]

    public struct Project: Codable, Sendable {
        public let path: String
        public let title: String?

        public init(path: String, title: String? = nil) {
            self.path = path
            self.title = title
        }
    }

    public init(version: Int = 1, projects: [Project]) {
        self.version = version
        self.projects = projects
    }
}

public struct VideoPublicationOrder: Codable, Sendable {
    public let version: Int
    public let projectIDs: [String]

    public init(version: Int = 1, projectIDs: [String]) {
        self.version = version
        self.projectIDs = projectIDs
    }
}

public enum VideoPublicationService {
    public struct Result: Codable, Sendable {
        public let version: Int
        public let path: String
        public let written: Bool
        public let manifest: VideoPublicationManifest
    }

    private struct Inspection {
        let revisions: [VideoEditorService.Revision]
        let protected: [URL]
    }

    public static func create(
        at output: URL, input: URL, dryRun: Bool = false, overwrite: Bool = false
    ) async throws -> Result {
        let data = try read(input)
        let plan: VideoPublicationPlan = try decode(data, kind: .plan)
        var items: [VideoPublicationManifest.Item] = []
        for (index, entry) in plan.projects.enumerated() {
            try Task.checkCancellation()
            let url = try resolve(entry.path, beside: input)
            let project = try projectSnapshot(url, index: index).project
            items.append(
                .init(
                    projectID: project.id, projectPath: url.path,
                    title: entry.title ?? project.title))
        }
        let manifest = VideoPublicationManifest(items: items)
        let inspection = try inspect(manifest, at: output)
        return try await save(
            manifest, at: output, inspection: inspection, input: input, inputData: data,
            dryRun: dryRun, overwrite: overwrite)
    }

    public static func show(_ url: URL) throws -> VideoPublicationManifest {
        let manifest: VideoPublicationManifest = try decode(read(url), kind: .manifest)
        _ = try inspect(manifest, at: url)
        return manifest
    }

    public static func reorder(
        _ url: URL, input: URL, dryRun: Bool = false, overwrite: Bool = false
    ) async throws -> Result {
        let lock = dryRun ? nil : try await VideoProjectFileAccess.transaction(url)
        defer { withExtendedLifetime(lock) {} }
        let before = try read(url)
        let manifest: VideoPublicationManifest = try decode(before, kind: .manifest)
        let data = try read(input)
        let order: VideoPublicationOrder = try decode(data, kind: .order)
        let inspection = try inspect(manifest, at: url)
        guard Set(order.projectIDs).count == order.projectIDs.count,
            Set(order.projectIDs) == Set(manifest.items.map(\.projectID))
        else {
            throw failure(
                "invalid_publication_order", "Order must contain every project ID exactly once.")
        }
        let byID = Dictionary(uniqueKeysWithValues: manifest.items.map { ($0.projectID, $0) })
        let reordered = VideoPublicationManifest(items: order.projectIDs.compactMap { byID[$0] })
        return try await save(
            reordered, at: url, inspection: inspection, input: input, inputData: data,
            dryRun: dryRun, overwrite: overwrite, previous: before)
    }

    private static func inspect(_ manifest: VideoPublicationManifest, at url: URL) throws
        -> Inspection
    {
        guard manifest.version == 1, (1...100).contains(manifest.items.count) else {
            throw failure("invalid_publication", "Expected version 1 and 1 to 100 projects.")
        }
        var ids = Set<String>()
        var paths: [URL] = []
        var revisions: [VideoEditorService.Revision] = []
        var protected: [URL] = []
        for (index, item) in manifest.items.enumerated() {
            try Task.checkCancellation()
            try text(item.projectID, maximum: 1000)
            try text(item.title, maximum: 1000)
            let path = try resolve(item.projectPath, beside: url)
            guard ids.insert(item.projectID).inserted,
                !paths.contains(where: { VideoProjectFileAccess.sameFile($0, path) })
            else {
                throw failure(
                    "invalid_publication_duplicate", "Item \(index): duplicate project ID or file.")
            }
            let snapshot = try projectSnapshot(path, index: index)
            guard snapshot.project.id == item.projectID else {
                throw failure(
                    "invalid_publication_identity",
                    "Item \(index): project ID no longer matches the referenced file.")
            }
            for source in VideoEditorService.sourceURLs(snapshot.project, includeSidecars: false) {
                try Task.checkCancellation()
                do {
                    try VideoEditorService.requireLocalFile(source)
                } catch {
                    throw failure(
                        "invalid_publication_reference",
                        "Item \(index): \(error.localizedDescription)")
                }
            }
            paths.append(path)
            revisions.append(snapshot.revision)
            protected.append(path)
            protected += VideoEditorService.sourceURLs(snapshot.project, includeSidecars: true)
        }
        return Inspection(revisions: revisions, protected: protected)
    }

    private static func projectSnapshot(_ url: URL, index: Int) throws
        -> (project: VideoProject, revision: VideoEditorService.Revision)
    {
        do {
            return try VideoEditorService.readProject(url)
        } catch {
            throw failure(
                "invalid_publication_reference", "Item \(index): \(error.localizedDescription)")
        }
    }

    private static func save(
        _ manifest: VideoPublicationManifest, at output: URL, inspection: Inspection,
        input: URL, inputData: Data, dryRun: Bool, overwrite: Bool, previous: Data? = nil
    ) async throws -> Result {
        try VideoEditorService.require(
            output.isFileURL && output.pathExtension.lowercased() == "json",
            "Publication output must be a local .json file.")
        let protected = inspection.protected + [input]
        func check() throws {
            try Task.checkCancellation()
            guard !protected.contains(where: { VideoProjectFileAccess.sameFile($0, output) }) else {
                throw failure(
                    "invalid_publication_output",
                    "Output must not replace a project, dependency, or input plan.")
            }
            for revision in inspection.revisions {
                try Task.checkCancellation()
                guard try revision.fingerprint.matches(revision.url) else {
                    throw failure(
                        "project_changed", "A referenced project changed. Read it again and retry.")
                }
            }
            guard try VideoProjectFileAccess.Revision(inputData).matches(input) else {
                throw failure("publication_changed", "Input plan changed. Read it again and retry.")
            }
            if let previous, try !VideoProjectFileAccess.Revision(previous).matches(output) {
                throw failure("publication_changed", "Manifest changed. Read it again and retry.")
            }
            try VideoEditorService.checkDestination(output, overwrite: overwrite)
            try Task.checkCancellation()
        }
        try check()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(manifest)
        guard data.count <= maximumBytes else {
            throw failure("invalid_publication", "Manifest exceeds 1 MiB.")
        }
        if !dryRun {
            let temporary = VideoEditorService.temporaryOutput(output)
            defer { try? FileManager.default.removeItem(at: temporary) }
            try data.write(to: temporary, options: .withoutOverwriting)
            try VideoProjectFileAccess.publication(output) {
                try check()
                try VideoEditorService.publish(temporary, to: output, overwrite: overwrite)
            }
        }
        return Result(version: 1, path: output.path, written: !dryRun, manifest: manifest)
    }

    private static let maximumBytes = 1024 * 1024

    private enum Kind {
        case plan, manifest, order
        var key: String {
            switch self {
            case .plan: "projects"
            case .manifest: "items"
            case .order: "projectIDs"
            }
        }
    }

    private static func decode<T: Decodable>(_ data: Data, kind: Kind) throws -> T {
        do {
            guard data.count <= maximumBytes,
                let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                Set(root.keys) == ["version", kind.key],
                let version = root["version"] as? NSNumber,
                CFGetTypeID(version) != CFBooleanGetTypeID(), version == 1,
                let entries = root[kind.key] as? [Any], (1...100).contains(entries.count)
            else {
                throw failure(
                    "invalid_publication",
                    "Expected version 1 and 1 to 100 entries; unknown fields are rejected.")
            }
            for entry in entries {
                if kind == .order {
                    guard let value = entry as? String else {
                        throw failure("invalid_publication", "Project IDs must be strings.")
                    }
                    try text(value, maximum: 1000)
                } else {
                    guard let object = entry as? [String: Any] else {
                        throw failure("invalid_publication", "Entries must be objects.")
                    }
                    let required: Set<String> =
                        kind == .plan ? ["path"] : ["projectID", "projectPath", "title"]
                    let allowed = kind == .plan ? required.union(["title"]) : required
                    guard required.isSubset(of: Set(object.keys)),
                        Set(object.keys).isSubset(of: allowed)
                    else {
                        throw failure("invalid_publication", "Entry has unknown or missing fields.")
                    }
                    for (key, value) in object {
                        guard let value = value as? String else {
                            throw failure("invalid_publication", "Entry fields must be strings.")
                        }
                        try text(
                            value, maximum: key == "path" || key == "projectPath" ? 4096 : 1000)
                    }
                }
            }
            return try JSONDecoder().decode(T.self, from: data)
        } catch let error as VideoEditorService.Failure { throw error } catch {
            throw failure("invalid_publication", error.localizedDescription)
        }
    }

    private static func text(_ value: String, maximum: Int) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            value.utf8.count <= maximum, !value.contains("\0")
        else {
            throw failure(
                "invalid_publication",
                "Fields must be nonempty and contain at most \(maximum) UTF-8 bytes without NUL.")
        }
    }

    private static func resolve(_ path: String, beside url: URL) throws -> URL {
        try text(path, maximum: 4096)
        return URL(fileURLWithPath: path, relativeTo: url.deletingLastPathComponent())
            .standardizedFileURL
    }

    private static func read(_ url: URL) throws -> Data {
        try Task.checkCancellation()
        try VideoEditorService.requireLocalFile(url)
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
            metadata.st_size <= maximumBytes
        else {
            throw failure("invalid_publication", "Expected a regular JSON file of at most 1 MiB.")
        }
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard data.count <= maximumBytes else {
            throw failure("invalid_publication", "JSON exceeds 1 MiB.")
        }
        return data
    }

    private static func failure(_ code: String, _ message: String) -> VideoEditorService.Failure {
        VideoEditorService.Failure(code, message)
    }
}
