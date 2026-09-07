import Foundation

public struct SkillInstaller: Sendable {
    public static let package = "skills@1.5.24"
    private let run: ToolInstaller.RunCommand

    public init(
        run: @escaping ToolInstaller.RunCommand = {
            try await CLICommandRunner.run($0, onLine: $1)
        }
    ) {
        self.run = run
    }

    public static func arguments(skill: CatalogSkill, agentIDs: [String]) throws -> [String] {
        let segments = skill.source.split(separator: "/", omittingEmptySubsequences: false)
        let validSegment: (String) -> Bool = {
            !$0.isEmpty && $0 != "." && $0 != ".." && !$0.hasPrefix("-")
                && $0.unicodeScalars.allSatisfy {
                    CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0)
                }
        }
        guard segments.count == 2, segments.allSatisfy({ validSegment(String($0)) }),
            validSegment(skill.skillId), !agentIDs.isEmpty,
            agentIDs.allSatisfy({ id in SkillAgentCatalog.agents.contains { $0.id == id } })
        else {
            throw SkillsError.message("Choose a GitHub skill and at least one supported agent.")
        }
        return [
            "--yes", package, "add", "https://github.com/" + skill.source,
            "--skill", skill.skillId, "--global", "--yes", "--copy", "--agent",
        ] + Array(Set(agentIDs)).sorted()
    }

    public func install(
        skill: CatalogSkill, agentIDs: [String],
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        log: @escaping ToolInstaller.Log = { _ in }
    ) async throws {
        let arguments = try Self.arguments(skill: skill, agentIDs: agentIDs)
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
            return FileManager.default.fileExists(
                atPath: agent.resolvedDirectory(home: home, environment: environment)
                    .appendingPathComponent(skill.skillId).appendingPathComponent("SKILL.md").path)
        }
        guard installed else {
            throw SkillsError.message(
                "The installer finished, but some selected agents are missing the skill. Check the output before retrying."
            )
        }
    }
}
