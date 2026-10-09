import Darwin
import Foundation

struct UsageNativeProject: Codable, Sendable {
    var repositoryID: String
    var repositoryName: String
    var repositoryURL: String?
    var folderName: String
    var root: String
    var worktree: String?
}

enum UsageNativeProjects {
    static func resolve(_ cwd: String, archive: UsageNativeArchive) throws -> UsageNativeProject {
        let key = "repository:" + UsageNativeJSON.hash(cwd)
        let markers = ["/.claude/worktrees/", "/.cursor/worktrees/"]
        let marker = markers.first { cwd.contains($0) }
        let base = marker.flatMap { cwd.components(separatedBy: $0).first }
        let worktree = marker.flatMap {
            cwd.components(separatedBy: $0).last?.split(separator: "/").first.map(String.init)
        }
        let path = base ?? cwd
        var exists = false
        if !path.isEmpty { exists = FileManager.default.fileExists(atPath: path) }
        if !exists, let cached = try archive.cached(key),
            let data = try? UsageNativeJSON.encode(cached),
            let saved = try? JSONDecoder().decode(UsageNativeProject.self, from: data)
        {
            return saved
        }
        let location = gitLocation(path)
        let root = location?.root ?? path
        let folder = root.isEmpty ? "Unattributed" : URL(fileURLWithPath: root).lastPathComponent
        let config = location.flatMap {
            try? String(
                decoding: UsageNativeFileIO.read($0.config, maximum: 1_048_576), as: UTF8.self)
        }
        let remote = config.flatMap(remoteIdentity)
        let name = remote?.split(separator: "/").last.map(String.init) ?? folder
        let project = UsageNativeProject(
            repositoryID: remote ?? "folder:" + root, repositoryName: name,
            repositoryURL: remote.map { "https://" + $0 }, folderName: folder, root: root,
            worktree: worktree ?? location?.worktree)
        let encoded = try JSONEncoder().encode(project)
        try archive.cache(UsageNativeJSON.object(encoded), key: key)
        return project
    }

    static func remoteIdentity(_ config: String) -> String? {
        var active: String?
        var remotes: [String: String] = [:]
        for raw in config.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("[") {
                active = nil
                if line.hasPrefix("[remote \""), line.hasSuffix("\"]") {
                    active = String(line.dropFirst(9).dropLast(2))
                }
            } else if let active, let equal = line.firstIndex(of: "="),
                line[..<equal].trimmingCharacters(in: .whitespaces) == "url"
            {
                remotes[active] = line[line.index(after: equal)...].trimmingCharacters(
                    in: .whitespaces
                ).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
        }
        for name in ["origin", "upstream"] + remotes.keys.sorted() {
            if let remote = remotes[name], let identity = githubIdentity(remote) { return identity }
        }
        return nil
    }

    static func githubIdentity(_ raw: String) -> String? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.hasPrefix("git@github.com:") {
            value = "https://github.com/" + value.dropFirst(15)
        }
        if value.hasPrefix("github.com/") { value = "https://" + value }
        guard let url = URLComponents(string: value), url.host == "github.com",
            ["https", "http", "ssh", "git"].contains(url.scheme ?? "")
        else { return nil }
        var path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if path.hasSuffix(".git") { path.removeLast(4) }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
            path.utf8.count <= 512
        else { return nil }
        return "github.com/" + path
    }

    private static func gitLocation(_ path: String) -> (
        root: String, config: URL, worktree: String?
    )? {
        guard path.hasPrefix("/") else { return nil }
        var probe = URL(fileURLWithPath: path).standardizedFileURL
        for _ in 0..<64 {
            let git = probe.appendingPathComponent(".git")
            var status = stat()
            if lstat(git.path, &status) == 0 {
                if status.st_mode & S_IFMT == S_IFDIR {
                    return (probe.path, git.appendingPathComponent("config"), nil)
                }
                if status.st_mode & S_IFMT == S_IFREG,
                    let data = try? UsageNativeFileIO.read(git, maximum: 4096),
                    let declaration = String(data: data, encoding: .utf8)?.trimmingCharacters(
                        in: .whitespacesAndNewlines),
                    declaration.hasPrefix("gitdir:")
                {
                    let directory = declaration.dropFirst(7).trimmingCharacters(in: .whitespaces)
                    let target =
                        directory.hasPrefix("/")
                        ? URL(fileURLWithPath: directory) : probe.appendingPathComponent(directory)
                    if let common = try? String(
                        decoding: UsageNativeFileIO.read(
                            target.appendingPathComponent("commondir"), maximum: 4096),
                        as: UTF8.self
                    ).trimmingCharacters(in: .whitespacesAndNewlines) {
                        let shared =
                            common.hasPrefix("/")
                            ? URL(fileURLWithPath: common)
                            : target.appendingPathComponent(common).standardizedFileURL
                        return (
                            shared.deletingLastPathComponent().path,
                            shared.appendingPathComponent("config"), probe.lastPathComponent
                        )
                    }
                    return (probe.path, target.appendingPathComponent("config"), nil)
                }
                return nil
            }
            let parent = probe.deletingLastPathComponent()
            if parent.path == probe.path { return nil }
            probe = parent
        }
        return nil
    }
}
