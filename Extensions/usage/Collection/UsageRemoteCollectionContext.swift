import Darwin
import Foundation

public struct UsageRemoteProjectMetadata: Codable, Equatable, Sendable {
    public let cwd: String
    public let root: String
    public let repositoryID: String
    public let repositoryName: String
    public let repositoryURL: String?
    public let folderName: String
    public let worktree: String?

    public init(
        cwd: String, root: String, repositoryID: String, repositoryName: String,
        repositoryURL: String? = nil, folderName: String, worktree: String? = nil
    ) {
        self.cwd = cwd; self.root = root; self.repositoryID = repositoryID
        self.repositoryName = repositoryName; self.repositoryURL = repositoryURL
        self.folderName = folderName; self.worktree = worktree
    }

    func validate() throws {
        guard Self.path(cwd), Self.path(root), Self.text(repositoryID, maximum: 2_048),
            Self.text(repositoryName, maximum: 1_024), Self.text(folderName, maximum: 1_024),
            worktree.map({ Self.text($0, maximum: 1_024) }) ?? true
        else { throw UsageNativeFailure.invalidInput("remote project metadata") }
        if let repositoryURL {
            guard Self.text(repositoryURL, maximum: 2_048),
                let url = URLComponents(string: repositoryURL),
                ["https", "http"].contains(url.scheme ?? ""),
                let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
                url.query == nil, url.fragment == nil
            else { throw UsageNativeFailure.invalidInput("remote repository URL") }
        }
    }

    static func text(_ value: String, maximum: Int) -> Bool {
        !value.isEmpty && value.utf8.count <= maximum
            && !value.unicodeScalars.contains {
                CharacterSet.controlCharacters.contains($0)
            }
    }

    private static func path(_ value: String) -> Bool {
        guard text(value, maximum: 4_096) else { return false }
        if value.hasPrefix("/") { return true }
        let bytes = Array(value.utf8.prefix(3))
        return bytes.count == 3 && ((65...90).contains(bytes[0]) || (97...122).contains(bytes[0]))
            && bytes[1] == 58 && (bytes[2] == 47 || bytes[2] == 92)
    }

    var project: UsageNativeProject {
        .init(
            repositoryID: repositoryID, repositoryName: repositoryName,
            repositoryURL: repositoryURL, folderName: folderName, root: root, worktree: worktree)
    }
}

public struct UsageRemoteCollectionContext: Codable, Equatable, Sendable {
    public let machineID: UUID
    public let projects: [UsageRemoteProjectMetadata]
    public let timeZone: String?

    public init(
        machineID: UUID, projects: [UsageRemoteProjectMetadata] = [], timeZone: String? = nil
    ) {
        self.machineID = machineID; self.projects = projects; self.timeZone = timeZone
    }

    func validate() throws {
        guard projects.count <= 10_000,
            timeZone.map({ $0.utf8.count <= 128 && TimeZone(identifier: $0) != nil }) ?? true
        else { throw UsageNativeFailure.invalidInput("remote collection context") }
        var bytes = 128
        for project in projects {
            try project.validate()
            bytes += try JSONEncoder().encode(project).count + 1
            guard bytes <= 4_194_304 else { throw UsageNativeFailure.capacity }
        }
        guard Set(projects.map(\.cwd)).count == projects.count,
            try JSONEncoder().encode(self).count <= 4_194_304
        else { throw UsageNativeFailure.invalidInput("remote collection context") }
    }

    func validateStagedHome(_ home: URL) throws {
        let root = home.resolvingSymlinksInPath().standardizedFileURL
        var enumerationFailure: Error?
        var metadata = stat()
        guard lstat(home.path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFDIR,
            metadata.st_uid == getuid(),
            metadata.st_mode & 0o077 == 0,
            let iterator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: nil,
                errorHandler: { _, error in
                    enumerationFailure = error; return false
                })
        else { throw UsageNativeFailure.unsafePath }
        var entries = 0
        var bytes: UInt64 = 0
        for case let path as URL in iterator {
            try Task.checkCancellation()
            entries += 1
            guard entries <= 100_000 else { throw UsageNativeFailure.capacity }
            guard lstat(path.path, &metadata) == 0 else { throw UsageNativeFailure.unsafePath }
            let type = metadata.st_mode & S_IFMT
            guard type == S_IFDIR || type == S_IFREG else { throw UsageNativeFailure.unsafePath }
            let relative = path.standardizedFileURL.pathComponents.dropFirst(
                root.pathComponents.count
            ).joined(
                separator: "/")
            guard ![".codex/auth.json", ".claude/.credentials.json"].contains(relative),
                !relative.hasSuffix("/.codex/auth.json"),
                !relative.hasSuffix("/.claude/.credentials.json")
            else {
                throw UsageNativeFailure.invalidInput("credentials in remote receipt snapshot")
            }
            if type == S_IFREG {
                guard metadata.st_size >= 0, metadata.st_size <= 134_217_728 else {
                    throw UsageNativeFailure.capacity
                }
                bytes += UInt64(metadata.st_size)
                guard bytes <= 536_870_912 else { throw UsageNativeFailure.capacity }
            }
        }
        if let enumerationFailure { throw enumerationFailure }
    }

    func journalKey(source: String, file: URL, home: URL) throws -> String {
        let base = home.resolvingSymlinksInPath().standardizedFileURL.path
        let path = file.resolvingSymlinksInPath().standardizedFileURL.path
        guard path.hasPrefix(base + "/") else {
            throw UsageNativeFailure.invalidInput("remote journal outside staged home")
        }
        let relative = String(path.dropFirst(base.count + 1))
        guard UsageRemoteProjectMetadata.text(relative, maximum: 16_384) else {
            throw UsageNativeFailure.invalidInput("remote journal path")
        }
        return source + ":"
            + UsageNativeJSON.hash(machineID.uuidString.lowercased() + "/" + relative)
    }
}
