import CryptoKit
import EdithCore
import EdithKit
import Foundation

extension VideoEditorService {
    public struct LibraryEntry: Codable, Sendable {
        public let path: String
        public let projectID: String
        public let title: String
        public let registered: Bool
        public var errorCode: String?
        public var error: String?
    }

    public struct OpenRequest: Codable, Sendable, Equatable {
        public let requestID: String
        public let path: String
        public let projectID: String
        public let revision: String

        public var payload: [String: String] {
            ["requestID": requestID, "path": path, "projectID": projectID, "revision": revision]
        }

        public func matches(_ payload: [AnyHashable: Any]) -> Bool {
            self.payload.allSatisfy { payload[$0.key] as? String == $0.value }
        }

        public init?(payload: [AnyHashable: Any]) {
            guard let requestID = payload["requestID"] as? String,
                UUID(uuidString: requestID) != nil,
                let path = payload["path"] as? String, path.hasPrefix("/"),
                let projectID = payload["projectID"] as? String, !projectID.isEmpty,
                let revision = payload["revision"] as? String, revision.count == 64
            else { return nil }
            self.requestID = requestID
            self.path = path
            self.projectID = projectID
            self.revision = revision
        }

        init(path: String, projectID: String, revision: String) {
            requestID = UUID().uuidString
            self.path = path
            self.projectID = projectID
            self.revision = revision
        }
    }

    public static func prepareOpen(_ url: URL) throws -> OpenRequest {
        let url = VideoProjectRegistry.canonical(url)
        let snapshot = try readProject(url)
        try VideoProjectRegistry().checkIdentity(snapshot.project, at: url)
        return OpenRequest(
            path: url.path, projectID: snapshot.project.id,
            revision: snapshot.revision.fingerprint.digest.map { String(format: "%02x", $0) }
                .joined())
    }

    public static func register(_ url: URL) throws -> LibraryEntry {
        let entry = try VideoProjectRegistry().register(url)
        IPC.post(IPC.Name.videoProjectLibraryChanged)
        return entry
    }

    public static func unregister(_ url: URL) throws -> LibraryEntry {
        let entry = try VideoProjectRegistry().unregister(url)
        IPC.post(IPC.Name.videoProjectLibraryChanged)
        return entry
    }

    public static func library() throws -> [LibraryEntry] {
        try VideoProjectRegistry().library()
    }
}

struct VideoProjectRegistry {
    let libraryURL: URL
    let legacyURL: URL?
    var directory: URL { libraryURL.appendingPathComponent(".registry", isDirectory: true) }

    init(libraryURL: URL = VideoProject.libraryURL, legacyURL: URL? = nil) {
        self.libraryURL = libraryURL
        self.legacyURL =
            legacyURL
            ?? (!AppBuildIdentity.isDevelopment
                && ProcessInfo.processInfo.environment[DataRoot.devOverrideVariable] == nil
                ? VideoProject.openScreenLibraryURL : nil)
    }

    static func canonical(_ url: URL) -> URL {
        url.resolvingSymlinksInPath().standardizedFileURL
    }

    private func recordURL(_ url: URL) -> URL {
        let digest = SHA256.hash(data: Data(VideoProjectFileAccess.identity(url).utf8))
            .map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(digest + ".json")
    }

    func records() throws -> [VideoEditorService.LibraryEntry] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension == "json" }
        .map {
            try JSONDecoder().decode(
                VideoEditorService.LibraryEntry.self, from: Data(contentsOf: $0))
        }
    }

    func checkIdentity(_ project: VideoProject, at url: URL) throws {
        if let existing = try records().first(where: {
            VideoProjectFileAccess.identity(URL(fileURLWithPath: $0.path))
                == VideoProjectFileAccess.identity(url)
        }), existing.projectID != project.id {
            throw VideoEditorService.Failure(
                "project_identity_changed",
                "The registered path now contains a different project. Unregister it before registering the replacement."
            )
        }
    }

    func register(_ source: URL) throws -> VideoEditorService.LibraryEntry {
        let url = Self.canonical(source)
        try VideoEditorService.require(
            url.pathExtension == "openscreen", "Expected an .openscreen project.")
        let project = try VideoEditorService.open(url)
        return try VideoProjectFileAccess.publication(directory) {
            try checkIdentity(project, at: url)
            if try records().contains(where: {
                $0.projectID == project.id
                    && VideoProjectFileAccess.identity(URL(fileURLWithPath: $0.path))
                        != VideoProjectFileAccess.identity(url)
            }) {
                throw VideoEditorService.Failure(
                    "project_id_conflict",
                    "This project identity is already registered at another path.")
            }
            let entry = VideoEditorService.LibraryEntry(
                path: url.path, projectID: project.id, title: project.title, registered: true)
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(entry).write(to: recordURL(url), options: .atomic)
            return entry
        }
    }

    func unregister(_ source: URL) throws -> VideoEditorService.LibraryEntry {
        let url = Self.canonical(source)
        return try VideoProjectFileAccess.publication(directory) {
            let record = recordURL(url)
            guard FileManager.default.fileExists(atPath: record.path) else {
                throw VideoEditorService.Failure(
                    "not_registered", "No registered reference exists for this path.")
            }
            let entry = try JSONDecoder().decode(
                VideoEditorService.LibraryEntry.self, from: Data(contentsOf: record))
            try FileManager.default.removeItem(at: record)
            return .init(
                path: entry.path, projectID: entry.projectID, title: entry.title, registered: false)
        }
    }

    func library() throws -> [VideoEditorService.LibraryEntry] {
        var entries = try records()
        var paths = Set(
            entries.map { VideoProjectFileAccess.identity(URL(fileURLWithPath: $0.path)) })
        for folder in [libraryURL, legacyURL].compactMap({ $0 }) {
            guard FileManager.default.fileExists(atPath: folder.path) else { continue }
            for url in try FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: nil)
            where url.pathExtension == "openscreen" {
                let url = Self.canonical(url)
                guard paths.insert(VideoProjectFileAccess.identity(url)).inserted else { continue }
                entries.append(
                    .init(
                        path: url.path, projectID: "",
                        title: url.deletingPathExtension().lastPathComponent, registered: false))
            }
        }
        return entries.map { entry in
            do {
                let project = try VideoEditorService.open(URL(fileURLWithPath: entry.path))
                if entry.registered, project.id != entry.projectID {
                    throw VideoEditorService.Failure(
                        "project_identity_changed",
                        "The registered path contains a different project.")
                }
                return .init(
                    path: entry.path, projectID: project.id, title: project.title,
                    registered: entry.registered)
            } catch {
                var failed = entry
                failed.errorCode =
                    (error as? VideoEditorService.Failure)?.code ?? "project_unavailable"
                failed.error = error.localizedDescription
                return failed
            }
        }.sorted { $0.path < $1.path }
    }
}
