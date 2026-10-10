import EdithExtensionSupport
import Foundation

public struct SkillInstaller: Sendable {
    public typealias RunCommand =
        @Sendable (CLICommandRequest, @escaping @Sendable (String) -> Void) async throws ->
        CLICommandResult
    public typealias Log = @Sendable (String) -> Void
    public static let package = "skills@1.5.24"
    private let recordInstalled: @Sendable (EdithSkill, SkillDocument) async throws -> Void
    private let run: RunCommand
    private let unavailableReason: String?

    public init(
        recordInstalled: @escaping @Sendable (EdithSkill, SkillDocument) async throws -> Void,
        unavailableReason: String? = nil,
        run: @escaping RunCommand = {
            try await CLICommandRunner.run($0, onLine: $1)
        }
    ) {
        self.recordInstalled = recordInstalled
        self.run = run
        self.unavailableReason = unavailableReason
    }

    public static func arguments(skill: EdithSkill, agentIDs: [String]) throws
        -> [String]
    {
        guard EdithSkillLibrary.skills.contains(skill),
            !agentIDs.isEmpty,
            agentIDs.allSatisfy({ id in SkillAgentCatalog.agents.contains { $0.id == id } })
        else {
            throw SkillsError.message(
                "Choose an Edith skill and at least one supported agent.")
        }
        return [
            "--yes", package, "add", skill.packageURL.absoluteString,
            "--skill", skill.id, "--global", "--yes", "--copy", "--agent",
        ] + Array(Set(agentIDs)).sorted()
    }

    public func install(
        skill: EdithSkill, agentIDs: [String],
        home: URL = ProcessInfo.processInfo.environment["EDITH_EXTENSION_FIXTURE_HOME"].map {
            URL(fileURLWithPath: $0)
        } ?? FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        log: @escaping Log = { _ in }
    ) async throws {
        try Task.checkCancellation()
        if let unavailableReason { throw SkillsError.message(unavailableReason) }
        let arguments = try Self.arguments(skill: skill, agentIDs: agentIDs)
        var environment = CLIToolEnvironment.sanitized(processEnvironment: environment)
        environment["HOME"] = home.path
        environment["NO_COLOR"] = "1"
        environment["CI"] = "1"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        let result = try await run(
            CLICommandRequest(
                executableURL: URL(fileURLWithPath: "/usr/bin/env"),
                arguments: ["npx"] + arguments, environment: environment,
                currentDirectoryURL: home, timeout: 300, maximumOutputBytes: 1_000_000,
                terminatesProcessGroup: true), log)
        try Task.checkCancellation()
        guard result.terminationStatus == 0 else {
            throw SkillsError.message(
                "Installation failed (exit \(result.terminationStatus)). Check the output and try again."
            )
        }
        var installed: [String: Data]?
        var document: SkillDocument?
        for id in Array(Set(agentIDs)).sorted() {
            try Task.checkCancellation()
            guard let agent = SkillAgentCatalog.agents.first(where: { $0.id == id }) else {
                throw SkillsError.message("Choose a supported agent.")
            }
            let directory = agent.resolvedDirectory(home: home, environment: environment)
                .appendingPathComponent(skill.id)
            let files: [String: Data]
            do {
                files = try Self.packageFiles(at: directory, skill: skill)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw SkillsError.message(
                    "The installer did not provide a complete skill for \(agent.name): \(error.localizedDescription)"
                )
            }
            guard installed == nil || installed == files else {
                throw SkillsError.message(
                    "Selected agents received different skill packages. Check the output before retrying."
                )
            }
            installed = files
            document = try SkillDocumentStore.decode(
                files["SKILL.md"] ?? Data(), skill: skill, cached: false)
        }
        guard let document else {
            throw SkillsError.message(
                "The installer finished without a verified skill. Check the output before retrying."
            )
        }
        try Task.checkCancellation()
        try await recordInstalled(skill, document)
    }

    private static func packageFiles(at directory: URL, skill: EdithSkill) throws -> [String: Data]
    {
        let root = directory.standardizedFileURL.resolvingSymlinksInPath()
        var files: [String: Data] = [:]
        var directories = [root]
        var visited = 0
        var bytes = 0
        while let folder = directories.popLast() {
            try Task.checkCancellation()
            for file in try FileManager.default.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey])
            {
                try Task.checkCancellation()
                visited += 1
                guard visited <= 4096 else {
                    throw SkillsError.message("The installed skill contains too many files.")
                }
                let resolved = file.standardizedFileURL.resolvingSymlinksInPath()
                guard resolved.path.hasPrefix(root.path + "/"),
                    resolved == file.standardizedFileURL
                else {
                    throw SkillsError.message("The installed skill contains an invalid file path.")
                }
                let attributes = try file.resourceValues(forKeys: [
                    .isDirectoryKey, .isRegularFileKey, .fileSizeKey,
                ])
                if attributes.isDirectory == true {
                    directories.append(resolved)
                } else {
                    guard attributes.isRegularFile == true,
                        let size = attributes.fileSize, size <= 16 * 1_024 * 1_024,
                        bytes + size <= 32 * 1_024 * 1_024
                    else {
                        throw SkillsError.message(
                            "The installed skill exceeds its file size limit.")
                    }
                    let handle = try FileHandle(forReadingFrom: resolved)
                    defer { try? handle.close() }
                    let data = try handle.read(upToCount: size + 1) ?? Data()
                    guard data.count == size else {
                        throw SkillsError.message(
                            "The installed skill changed during verification.")
                    }
                    bytes += data.count
                    files[String(resolved.path.dropFirst(root.path.count + 1))] = data
                }
            }
        }
        _ = try SkillDocumentStore.decode(files["SKILL.md"] ?? Data(), skill: skill, cached: false)
        let links = try NSRegularExpression(pattern: #"\]\(([^\s)]+)\)"#)
        for (name, data) in files where name.hasSuffix(".md") {
            try Task.checkCancellation()
            guard let markdown = String(data: data, encoding: .utf8) else {
                throw SkillsError.message("The installed skill contains invalid Markdown.")
            }
            let text = markdown as NSString
            let range = NSRange(location: 0, length: text.length)
            for match in links.matches(in: markdown, range: range) {
                let link = text.substring(with: match.range(at: 1))
                if link.hasPrefix("#") || URL(string: link)?.scheme != nil { continue }
                let path = link.split(separator: "#", maxSplits: 1).first.map(String.init) ?? ""
                let target = root.appendingPathComponent(name).deletingLastPathComponent()
                    .appendingPathComponent(path.removingPercentEncoding ?? path)
                    .standardizedFileURL
                guard target.path.hasPrefix(root.path + "/"),
                    files[String(target.path.dropFirst(root.path.count + 1))] != nil
                else {
                    throw SkillsError.message(
                        "The installed skill is missing a local reference: \(link). Check the output before retrying."
                    )
                }
            }
        }
        return files
    }
}
