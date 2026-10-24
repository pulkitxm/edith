import EdithExtensionSupport
import CryptoKit
import Foundation

public enum CodeStatsGitError: Error, Equatable, Sendable {
    case failed(status: Int32, message: String)
}

final class CodeStatsLocked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    func update<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.withLock { body(&value) }
    }
}

public struct CodeStatsAuthor: Codable, Equatable, Sendable {
    public var name: String
    public var email: String
    public var commits: Int

    public init(name: String, email: String, commits: Int) {
        self.name = name
        self.email = email
        self.commits = commits
    }
}

public struct CodeStatsGit: Sendable {
    public static let defaultNetworkTimeout: TimeInterval = 7_200
    public static let sshCommand =
        "ssh -o BatchMode=yes -o ConnectTimeout=30 -o ServerAliveInterval=15"
        + " -o ServerAliveCountMax=4"
    static let commandLineToolsShim = "/usr/bin/git"
    static let historyRefs = ["--branches", "--tags", "--remotes"]
    static let historyRefPrefixes = ["refs/heads", "refs/tags", "refs/remotes"]
    static let pullRefspec = "+refs/pull/*/head:refs/pull/*/head"

    public let executable: URL
    public let environment: [String: String]
    public let credentialHelper: URL?
    public let networkTimeout: TimeInterval

    public init(
        executable: URL, environment: [String: String], credentialHelper: URL? = nil,
        networkTimeout: TimeInterval = CodeStatsGit.defaultNetworkTimeout
    ) {
        self.executable = executable
        self.environment = environment.merging(
            ["GIT_TERMINAL_PROMPT": "0", "GCM_INTERACTIVE": "never"]
        ) { _, forced in forced }
        self.credentialHelper = credentialHelper
        self.networkTimeout = networkTimeout
    }

    public static func resolve(credentialHelper: URL? = nil) async -> CodeStatsGit? {
        await resolve(
            candidate: CLIToolEnvironment.executable(named: "git"),
            environment: CLIToolEnvironment.sanitized(), credentialHelper: credentialHelper,
            developerDirectory: { await activeDeveloperDirectory() })
    }

    static func resolve(
        candidate: URL?, environment: [String: String], credentialHelper: URL? = nil,
        developerDirectory: @Sendable () async -> String?
    ) async -> CodeStatsGit? {
        guard let candidate else { return nil }
        if candidate.standardizedFileURL.path == commandLineToolsShim {
            guard let directory = await developerDirectory(),
                FileManager.default.isExecutableFile(atPath: directory + "/usr/bin/git")
            else { return nil }
        }
        let git = CodeStatsGit(
            executable: candidate, environment: environment, credentialHelper: credentialHelper)
        guard (try? await git.run(["--version"], timeout: 30)) != nil else { return nil }
        return git
    }

    static func activeDeveloperDirectory() async -> String? {
        if let configured = ProcessInfo.processInfo.environment["DEVELOPER_DIR"],
            !configured.isEmpty
        {
            return configured
        }
        let result = try? await CLICommandRunner.runLocalSeparated(
            CLICommandRequest(
                executableURL: URL(fileURLWithPath: "/usr/bin/xcode-select"), arguments: ["-p"],
                environment: CLIToolEnvironment.sanitized(), timeout: 30),
            onStandardOutputLine: { _ in }, onStandardErrorLine: { _ in })
        guard let result, result.terminationStatus == 0 else { return nil }
        let directory = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        return directory.isEmpty ? nil : directory
    }

    private var baseArguments: [String] {
        [
            "-c", "core.quotePath=false", "-c", "log.showSignature=false", "-c", "color.ui=false",
        ]
    }

    func networkArguments(in directory: String?) async -> [String] {
        var arguments = ["-c", "http.lowSpeedLimit=1000", "-c", "http.lowSpeedTime=120"]
        if environment["GIT_SSH_COMMAND"] == nil, environment["GIT_SSH"] == nil,
            (try? await run(["config", "--get", "core.sshCommand"], in: directory, timeout: 30))
                == nil
        {
            arguments += ["-c", "core.sshCommand=" + Self.sshCommand]
        }
        if let credentialHelper {
            let quoted = "'" + credentialHelper.path.replacingOccurrences(of: "'", with: "'\\''")
            arguments += [
                "-c", "credential.https://github.com.helper=",
                "-c", "credential.https://github.com.helper=!" + quoted + "' auth git-credential",
            ]
        }
        return arguments
    }

    @discardableResult
    private func run(
        _ arguments: [String], in directory: String? = nil, network: Bool = false,
        timeout: TimeInterval? = nil, extraEnvironment: [String: String] = [:],
        input: Data? = nil, onLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> CLICommandResult {
        let prefix = network ? await networkArguments(in: directory) : []
        let request = CLICommandRequest(
            executableURL: executable,
            arguments: baseArguments + prefix + arguments,
            environment: environment.merging(extraEnvironment) { _, extra in extra },
            currentDirectoryURL: directory.map { URL(fileURLWithPath: $0) },
            timeout: network ? networkTimeout : timeout,
            maximumOutputBytes: 1_048_576, standardInputData: input,
            terminatesProcessGroup: true)
        let result = try await CLICommandRunner.runLocalSeparated(
            request, retainsStandardOutput: onLine == nil,
            onStandardOutputLine: onLine ?? { _ in }, onStandardErrorLine: { _ in })
        guard result.terminationStatus == 0 else {
            throw CodeStatsGitError.failed(
                status: result.terminationStatus,
                message: result.standardError.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return result
    }

    public func refsFingerprint(_ repository: CodeStatsRepository) async throws -> String {
        try await refState(repository).fingerprint
    }

    public func refState(_ repository: CodeStatsRepository) async throws -> CodeStatsRefState {
        let lines = CodeStatsLocked([String]())
        try await run(
            ["for-each-ref", "--format=%(objectname) %(refname)"] + Self.historyRefPrefixes,
            in: repository.path,
            onLine: { line in lines.update { $0.append(line) } })
        return CodeStatsRefState(lines: lines.update { $0 })
    }

    public func commits(
        in repository: CodeStatsRepository, identity: CodeStatsIdentity
    ) async throws -> [CodeStatsCommit] {
        try await commits(
            in: repository, attribution: CodeStatsAttribution(identity: identity, owned: false))
    }

    public func commits(
        in repository: CodeStatsRepository, attribution: CodeStatsAttribution,
        excluding previousTips: [String] = []
    ) async throws -> [CodeStatsCommit] {
        let candidates = try await candidateCommits(
            in: repository, attribution: attribution, excluding: previousTips)
        var commits: [CodeStatsCommit] = []
        var start = 0
        while start < candidates.count {
            let end = min(start + Self.chunkSize, candidates.count)
            commits += try await self.commits(
                in: repository, candidates: Array(candidates[start..<end]),
                attribution: attribution)
            start = end
        }
        return commits
    }

    public static let chunkSize = 250

    public func candidateCommits(
        in repository: CodeStatsRepository, attribution: CodeStatsAttribution,
        excluding previousTips: [String] = []
    ) async throws -> [CodeStatsCandidate] {
        try await candidateCommits(
            in: repository, attribution: attribution,
            revisions: Self.historyRefs + (previousTips.isEmpty ? [] : ["--not"] + previousTips))
    }

    func candidateCommits(
        in repository: CodeStatsRepository, attribution: CodeStatsAttribution,
        revisions: [String]
    ) async throws -> [CodeStatsCandidate] {
        guard !attribution.identity.isEmpty else { return [] }
        let candidates = CodeStatsLocked([CodeStatsCandidate]())
        try await run(
            ["rev-list", "--no-merges", "--regexp-ignore-case", "--extended-regexp"]
                + attribution.authorPatterns.map { "--author=" + $0 }
                + ["--format=" + CodeStatsLogParser.prettyFormat] + revisions,
            in: repository.path,
            onLine: { line in
                guard line.hasPrefix(CodeStatsLogParser.headerPrefix) else { return }
                let sha = line.split(separator: "\t", maxSplits: 2).dropFirst().first
                guard let sha else { return }
                candidates.update {
                    $0.append(CodeStatsCandidate(sha: String(sha), header: line))
                }
            })
        return candidates.update { $0 }
    }

    public func commits(
        in repository: CodeStatsRepository, candidates: [CodeStatsCandidate],
        attribution: CodeStatsAttribution
    ) async throws -> [CodeStatsCommit] {
        guard !candidates.isEmpty else { return [] }
        let attribute: CodeStatsLogParser.Attribute = { name, email, coAuthors in
            attribution.flags(name: name, email: email, coAuthors: coAuthors)
        }
        let parser = CodeStatsLocked(
            CodeStatsLogParser(repository: repository.fullName, attribute: attribute))
        let shas = candidates.map(\.sha)
        try await run(
            [
                "log", "--no-walk=unsorted", "--stdin",
                "--pretty=format:" + CodeStatsLogParser.prettyFormat, "-p", "-U0", "-M",
                "--no-color", "--no-ext-diff", "--no-textconv", "--src-prefix=a/",
                "--dst-prefix=b/", "--", ".",
            ] + CodeStatsLanguage.excludedPathspecs,
            in: repository.path, input: Data((shas.joined(separator: "\n") + "\n").utf8),
            onLine: { line in parser.update { $0.push(line) } })
        var commits = parser.update { $0.finish() }
        let parsed = Set(commits.map(\.sha))
        var headers = CodeStatsLogParser(repository: repository.fullName, attribute: attribute)
        for candidate in candidates where !parsed.contains(candidate.sha) {
            headers.push(candidate.header)
        }
        commits += headers.finish()
        return commits
    }

    public func canExtend(
        _ repository: CodeStatsRepository, from previousTips: [String]
    ) async -> Bool {
        guard !previousTips.isEmpty else { return false }
        let output = CodeStatsLocked("")
        do {
            try await run(
                ["rev-list", "--count"] + previousTips + ["--not"] + Self.historyRefs,
                in: repository.path,
                onLine: { line in output.update { $0 += line } })
        } catch {
            return false
        }
        return output.update { $0.trimmingCharacters(in: .whitespaces) } == "0"
    }

    public func integratedCommits(in repository: CodeStatsRepository) async throws -> Set<String> {
        let head = CodeStatsLocked([String]())
        do {
            try await run(
                ["rev-parse", "HEAD", "HEAD^{tree}"], in: repository.path,
                onLine: { line in head.update { $0.append(line) } })
        } catch {
            return []
        }
        let resolved = head.update { $0 }
        guard resolved.count == 2 else { return [] }
        let tree = resolved[1]
        let branches = CodeStatsLocked([String]())
        try await run(
            [
                "for-each-ref", "--no-merged=HEAD", "--format=%(refname)", "refs/heads",
                "refs/remotes",
            ],
            in: repository.path,
            onLine: { line in
                if !line.hasSuffix("/HEAD") { branches.update { $0.append(line) } }
            })
        let candidates = branches.update { $0 }
        guard !candidates.isEmpty else { return [] }
        let isolated = try await IsolatedObjects(git: self, repository: repository)
        defer { isolated.remove() }
        var integrated = Set<String>()
        for branch in candidates {
            if Task.isCancelled { break }
            let merged = CodeStatsLocked("")
            do {
                try await run(
                    ["merge-tree", "--write-tree", "HEAD", branch], in: repository.path,
                    extraEnvironment: isolated.environment,
                    onLine: { line in merged.update { if $0.isEmpty { $0 = line } } })
            } catch {
                continue
            }
            guard merged.update({ $0 }) == tree else { continue }
            let unique = CodeStatsLocked([String]())
            try await run(
                ["rev-list", "--no-merges", branch, "^HEAD"], in: repository.path,
                onLine: { line in unique.update { $0.append(line) } })
            integrated.formUnion(unique.update { $0 })
        }
        return integrated
    }

    public func pullHeads(in repository: CodeStatsRepository) async throws -> [Int: String] {
        let heads = CodeStatsLocked([Int: String]())
        try await run(
            ["for-each-ref", "--format=%(objectname) %(refname)", "refs/pull"],
            in: repository.path,
            onLine: { line in
                let parts = line.split(separator: " ", maxSplits: 1)
                guard parts.count == 2 else { return }
                let name = parts[1].split(separator: "/")
                guard name.count == 4, name[3] == "head", let number = Int(name[2]) else { return }
                heads.update { $0[number] = String(parts[0]) }
            })
        return heads.update { $0 }
    }

    public func squashes(
        in repository: CodeStatsRepository, candidates: [CodeStatsCandidate],
        attribution: CodeStatsAttribution
    ) async throws -> [CodeStatsSquash] {
        let heads = try await pullHeads(in: repository)
        let numbered = candidates.compactMap { candidate -> (sha: String, head: String)? in
            guard let number = CodeStatsLogParser.pullRequest(header: candidate.header),
                let head = heads[number]
            else { return nil }
            return (candidate.sha, head)
        }
        guard !numbered.isEmpty else { return [] }
        let shapes = CodeStatsLocked([String: (parent: String, tree: String)]())
        try await run(
            ["log", "--no-walk=unsorted", "--stdin", "--format=%H %T %P"], in: repository.path,
            input: Data((numbered.map(\.sha).joined(separator: "\n") + "\n").utf8),
            onLine: { line in
                let parts = line.split(separator: " ").map(String.init)
                guard parts.count == 3 else { return }
                shapes.update { $0[parts[0]] = (parts[2], parts[1]) }
            })
        let shape = shapes.update { $0 }
        let pairs = numbered.compactMap { entry in
            shape[entry.sha].map {
                (sha: entry.sha, head: entry.head, parent: $0.parent, tree: $0.tree)
            }
        }
        guard !pairs.isEmpty else { return [] }
        let trees = try await mergedTrees(
            in: repository, pairs: pairs.map { ($0.parent, $0.head) })
        var squashes: [CodeStatsSquash] = []
        for (pair, tree) in zip(pairs, trees) where tree == pair.tree {
            if Task.isCancelled { break }
            let originals = try await candidateCommits(
                in: repository, attribution: attribution, revisions: [pair.head, "^" + pair.parent])
            guard !originals.isEmpty else { continue }
            squashes.append(CodeStatsSquash(sha: pair.sha, originals: originals))
        }
        return squashes
    }

    func mergedTrees(
        in repository: CodeStatsRepository, pairs: [(String, String)]
    ) async throws -> [String?] {
        let isolated = try await IsolatedObjects(git: self, repository: repository)
        defer { isolated.remove() }
        let output = CodeStatsLocked("")
        try await run(
            ["merge-tree", "--stdin", "--name-only", "--no-messages"], in: repository.path,
            extraEnvironment: isolated.environment,
            input: Data(pairs.map { $0.0 + " " + $0.1 + "\n" }.joined().utf8),
            onLine: { line in output.update { $0 += line } })
        var trees: [String?] = []
        var fields = output.update { $0 }.split(separator: "\0", omittingEmptySubsequences: false)
            .makeIterator()
        while trees.count < pairs.count, let status = fields.next() {
            let tree = fields.next().map(String.init)
            while let field = fields.next(), !field.isEmpty {}
            trees.append(status == "1" ? tree : nil)
        }
        return trees + Array(repeating: nil, count: pairs.count - trees.count)
    }

    struct IsolatedObjects {
        let scratch: URL
        let environment: [String: String]

        init(git: CodeStatsGit, repository: CodeStatsRepository) async throws {
            let objects = CodeStatsLocked("")
            try await git.run(
                ["rev-parse", "--path-format=absolute", "--git-path", "objects"],
                in: repository.path, onLine: { line in objects.update { $0 = line } })
            scratch = FileManager.default.temporaryDirectory.appendingPathComponent(
                "code-stats-merge-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(
                at: scratch, withIntermediateDirectories: true)
            environment = [
                "GIT_OBJECT_DIRECTORY": scratch.path,
                "GIT_ALTERNATE_OBJECT_DIRECTORIES": objects.update { $0 },
            ]
        }

        func remove() {
            try? FileManager.default.removeItem(at: scratch)
        }
    }

    public func authors(in repository: CodeStatsRepository) async throws -> [CodeStatsAuthor] {
        let counts = CodeStatsLocked([String: Int]())
        try await run(
            ["log"] + Self.historyRefs + ["--no-merges", "--pretty=format:%an%x09%ae"],
            in: repository.path,
            onLine: { line in counts.update { $0[line, default: 0] += 1 } })
        return counts.update { $0 }.map { key, count in
            let parts = key.split(separator: "\t", maxSplits: 1).map(String.init)
            return CodeStatsAuthor(
                name: parts.first ?? "", email: parts.count > 1 ? parts[1] : "", commits: count)
        }
    }

    func credentialEnvironment(token: String?) -> [String: String] {
        guard credentialHelper != nil, let token else { return [:] }
        return ["GH_TOKEN": token]
    }

    public func cloneMirror(from url: String, to destination: URL, token: String? = nil)
        async throws
    {
        let owner = destination.deletingLastPathComponent()
        let staging = CodeStatsRepositoryDiscovery.stagingURL(for: destination)
        try Self.ensureDirectory(owner)
        do {
            try await run(
                ["clone", "--bare", "--quiet", url, staging.path], in: owner.path, network: true,
                extraEnvironment: credentialEnvironment(token: token))
            try await run(
                ["config", "remote.origin.fetch", "+refs/heads/*:refs/heads/*"], in: staging.path)
            try await run(
                ["config", "--add", "remote.origin.fetch", Self.pullRefspec], in: staging.path)
            try await run(
                ["fetch", "--quiet", "origin"], in: staging.path, network: true,
                extraEnvironment: credentialEnvironment(token: token))
            try FileManager.default.moveItem(at: staging, to: destination)
        } catch {
            DispatchQueue.global(qos: .utility).async {
                try? FileManager.default.removeItem(at: staging)
            }
            throw error
        }
    }

    public func fetch(_ repository: CodeStatsRepository, token: String? = nil) async throws {
        if repository.isBare {
            let refspecs = CodeStatsLocked([String]())
            try? await run(
                ["config", "--get-all", "remote.origin.fetch"], in: repository.path,
                onLine: { line in refspecs.update { $0.append(line) } })
            if !refspecs.update({ $0 }).contains(Self.pullRefspec) {
                try await run(
                    ["config", "--add", "remote.origin.fetch", Self.pullRefspec],
                    in: repository.path)
            }
        }
        try await run(
            ["fetch", "--all", "--prune", "--quiet"], in: repository.path, network: true,
            extraEnvironment: credentialEnvironment(token: token))
    }

    private static func ensureDirectory(_ url: URL) throws {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        } catch {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                isDirectory.boolValue
            else { throw error }
        }
    }
}
