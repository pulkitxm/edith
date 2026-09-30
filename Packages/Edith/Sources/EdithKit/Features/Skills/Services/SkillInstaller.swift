import Foundation

public struct SkillInstaller: Sendable {
    public static let package = "skills@1.5.24"
    private let recordInstalled: @Sendable (EdithSkill, SkillDocument) async throws -> Void
    private let run: ToolInstaller.RunCommand

    public init(
        recordInstalled: @escaping @Sendable (EdithSkill, SkillDocument) async throws -> Void = {
            skill, document in
            try await MainActor.run {
                try SkillDocumentStore.shared.recordInstalled(document, for: skill)
            }
        },
        run: @escaping ToolInstaller.RunCommand = {
            try await CLICommandRunner.run($0, onLine: $1)
        }
    ) {
        self.recordInstalled = recordInstalled
        self.run = run
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
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        log: @escaping ToolInstaller.Log = { _ in }
    ) async throws {
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
        guard result.terminationStatus == 0 else {
            throw SkillsError.message(
                "Installation failed (exit \(result.terminationStatus)). Check the output and try again."
            )
        }
        var installed: [String: Data]?
        var document: SkillDocument?
        for id in Array(Set(agentIDs)).sorted() {
            guard let agent = SkillAgentCatalog.agents.first(where: { $0.id == id }) else {
                throw SkillsError.message("Choose a supported agent.")
            }
            let directory = agent.resolvedDirectory(home: home, environment: environment)
                .appendingPathComponent(skill.id)
            let files: [String: Data]
            do {
                files = try Self.packageFiles(at: directory, skill: skill)
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
        try await recordInstalled(skill, document)
    }

    private static func packageFiles(at directory: URL, skill: EdithSkill) throws -> [String: Data]
    {
        let root = directory.standardizedFileURL.resolvingSymlinksInPath()
        var files: [String: Data] = [:]
        var directories = [root]
        while let folder = directories.popLast() {
            for file in try FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.isDirectoryKey])
            {
                let resolved = file.standardizedFileURL.resolvingSymlinksInPath()
                guard resolved.path.hasPrefix(root.path + "/"),
                    resolved == file.standardizedFileURL
                else {
                    throw SkillsError.message("The installed skill contains an invalid file path.")
                }
                if try file.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
                    directories.append(resolved)
                } else {
                    files[String(resolved.path.dropFirst(root.path.count + 1))] =
                        try Data(contentsOf: resolved)
                }
            }
        }
        _ = try SkillDocumentStore.decode(files["SKILL.md"] ?? Data(), skill: skill, cached: false)
        let links = try NSRegularExpression(pattern: #"\]\(([^\s)]+)\)"#)
        for (name, data) in files where name.hasSuffix(".md") {
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
