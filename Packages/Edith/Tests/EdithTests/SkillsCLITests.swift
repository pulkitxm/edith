import Foundation
import Testing

@testable import EdithCLI
@testable import EdithKit

@Suite struct SkillsCLITests {
    @Test func unknownSkillIsRejectedBeforeAnyInstall() {
        #expect(throws: CLIFailure.self) { try SkillsCLI.skill("missing-skill") }
    }

    @Test func agentIdsMustBelongToTheCatalog() throws {
        #expect(throws: CLIFailure.self) { try SkillsCLI.agents(["not-an-agent"]) }
        #expect(throws: CLIFailure.self) { try SkillsCLI.agents([]) }
        #expect(try SkillsCLI.agents(["cursor", "cursor"]) == ["cursor"])
    }

    @Test func installArgumentsMatchTheSheet() throws {
        let skill = try SkillsCLI.skill("edith-remote-work")
        let arguments = try SkillInstaller.arguments(skill: skill, agentIDs: ["cursor"])
        #expect(arguments.contains("edith-remote-work"))
        #expect(arguments.contains("cursor"))
        #expect(arguments.contains("--copy"))
    }

    @Test func helpNamesTheListExample() {
        #expect(SkillsCommand.helpMessage(columns: 200).contains("ed skills ls --json"))
        #expect(SkillsListCommand.helpMessage(columns: 200).contains("ed skills ls --json"))
        #expect(
            SkillsInstallCommand.helpMessage(columns: 200).contains(
                "ed skills install edith-remote-work --agent cursor --yes"))
    }
}
