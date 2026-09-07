import Foundation

public struct SkillInstaller: Sendable {
    public static let package = "skills@1.5.24"
    private let load: @Sendable (EdithSkill) async throws -> SkillDocument
    private let run: ToolInstaller.RunCommand

    public init(
        load: @escaping @Sendable (EdithSkill) async throws -> SkillDocument = {
            try await SkillDocumentStore.shared.load($0)
        },
        run: @escaping ToolInstaller.RunCommand = {
            try await CLICommandRunner.run($0, onLine: $1)
        }
    ) {
        self.load = load
        self.run = run
    }

    public static func arguments(skill: EdithSkill, directory: URL, agentIDs: [String]) throws
        -> [String]
    {
        guard EdithSkillLibrary.skills.contains(where: { $0.id == skill.id }),
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("SKILL.md").path),
            !agentIDs.isEmpty,
            agentIDs.allSatisfy({ id in SkillAgentCatalog.agents.contains { $0.id == id } })
        else {
            throw SkillsError.message(
                "Choose an Edith skill and at least one supported agent.")
        }
        return [
            "--yes", package, "add", directory.path,
            "--skill", skill.id, "--global", "--yes", "--copy", "--agent",
        ] + Array(Set(agentIDs)).sorted()
    }

    public func install(
        skill: EdithSkill, agentIDs: [String],
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        log: @escaping ToolInstaller.Log = { _ in }
    ) async throws {
        let document = try await load(skill)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "edith-skill-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let expected = Data(document.markdown.utf8)
        try expected.write(to: directory.appendingPathComponent("SKILL.md"), options: .atomic)
        if document.isCached { log("Using the cached skill because GitHub is unavailable.") }
        let arguments = try Self.arguments(skill: skill, directory: directory, agentIDs: agentIDs)
        var environment = CLIToolEnvironment.sanitized(processEnvironment: environment)
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
        let installed = agentIDs.allSatisfy { id in
            guard let agent = SkillAgentCatalog.agents.first(where: { $0.id == id }) else {
                return false
            }
            let destination = agent.resolvedDirectory(home: home, environment: environment)
                .appendingPathComponent(skill.id).appendingPathComponent("SKILL.md")
            return (try? Data(contentsOf: destination)) == expected
        }
        guard installed else {
            throw SkillsError.message(
                "The installer finished, but some selected agents are missing the skill. Check the output before retrying."
            )
        }
    }
}
