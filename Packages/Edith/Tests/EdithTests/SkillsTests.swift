import Foundation
import Testing

@testable import Edith
@testable import EdithCore
@testable import EdithKit

@Suite struct SkillsTests {
    private let skill = EdithSkillLibrary.skills[0]

    @Test func libraryContainsOnlyTheRequestedBundledSkill() throws {
        #expect(EdithSkillLibrary.skills.map(\.id) == ["edith-remote-work"])
        let directory = try #require(skill.directory)
        let instructions = try String(
            contentsOf: directory.appendingPathComponent("SKILL.md"), encoding: .utf8)
        #expect(instructions.hasPrefix("---\nname: edith-remote-work\n"))
        #expect(!instructions.contains("tuf-wired"))
    }

    @Test func installerTargetsExactlyTheSelectedAgentsWithoutAShell() throws {
        let arguments = try SkillInstaller.arguments(
            skill: skill, agentIDs: ["cursor", "claude-code", "cursor"])
        #expect(arguments.suffix(3) == ["--agent", "claude-code", "cursor"])
        #expect(arguments.contains("--global"))
        #expect(arguments.contains("--copy"))
        #expect(arguments.contains(try #require(skill.directory).path))
        #expect(!arguments.contains("*"))
        #expect(throws: SkillsError.self) {
            try SkillInstaller.arguments(skill: skill, agentIDs: [])
        }
        #expect(throws: SkillsError.self) {
            try SkillInstaller.arguments(skill: skill, agentIDs: ["unknown"])
        }
        let invalid = EdithSkill(
            id: "../other", name: "Other", summary: "", detail: "", symbol: "terminal")
        #expect(throws: SkillsError.self) {
            try SkillInstaller.arguments(skill: invalid, agentIDs: ["cursor"])
        }
    }

    @Test func agentDetectionRespectsCustomHomes() throws {
        let home = URL(fileURLWithPath: "/temporary/home")
        let agent = try #require(SkillAgentCatalog.agents.first { $0.id == "claude-code" })
        #expect(
            agent.isDetected(
                home: home, environment: ["CLAUDE_CONFIG_DIR": "/custom/config"],
                exists: { $0 == "/custom/config" }))
        #expect(
            agent.resolvedDirectory(
                home: home, environment: ["CLAUDE_CONFIG_DIR": "/custom/config"]
            ).path == "/custom/config/skills")
        #expect(!agent.isDetected(home: home, environment: [:], exists: { _ in false }))
        #expect(Set(SkillAgentCatalog.agents.map(\.id)).count == SkillAgentCatalog.agents.count)
    }

    @MainActor @Test func selectionPersistsAcrossSkillsAndNewModelsIncludingAllOff() throws {
        let name = "com.pulkit.edith.tests.skills.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let agents = Array(SkillAgentCatalog.agents.prefix(2))
        let model = SkillsModel(defaults: defaults, detectAgents: { agents })
        model.present(skill)
        #expect(model.selectedAgentIDs == Set(agents.map(\.id)))
        for agent in agents { model.setSelected(agent.id, enabled: false) }
        model.present(
            EdithSkill(id: "other", name: "Other", summary: "", detail: "", symbol: "terminal"))
        #expect(model.selectedAgentIDs.isEmpty)
        let reopened = SkillsModel(defaults: defaults, detectAgents: { agents })
        reopened.present(skill)
        #expect(reopened.selectedAgentIDs.isEmpty)
        reopened.present(skill, agentID: agents[0].id)
        #expect(reopened.selectedAgentIDs == [agents[0].id])
        reopened.present(skill)
        #expect(reopened.selectedAgentIDs.isEmpty)
        reopened.setSelected(agents[1].id, enabled: true)
        model.present(skill)
        #expect(model.selectedAgentIDs == [agents[1].id])
    }

    @MainActor @Test func newAgentsDefaultOnWithoutReenablingOptedOutAgents() throws {
        let name = "com.pulkit.edith.tests.skills.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let agents = Array(SkillAgentCatalog.agents.prefix(2))
        let model = SkillsModel(defaults: defaults, detectAgents: { [agents[0]] })
        model.present(skill)
        model.setSelected(agents[0].id, enabled: false)
        let replacement = SkillsModel(defaults: defaults, detectAgents: { agents })
        replacement.present(skill)
        #expect(replacement.selectedAgentIDs == [agents[1].id])
    }

    @Test func installerDoesNotReportSuccessOnFailedOrMissingFiles() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        for status: Int32 in [1, 0] {
            let installer = SkillInstaller { request, _ in
                #expect(request.executableURL.path == "/usr/bin/env")
                #expect(request.arguments.first == "npx")
                #expect(request.terminatesProcessGroup)
                #expect(request.timeout == 300)
                return CLICommandResult(terminationStatus: status, output: "installer output")
            }
            await #expect(throws: SkillsError.self) {
                try await installer.install(
                    skill: skill, agentIDs: ["cursor"], home: home, environment: [:])
            }
        }
    }

    @Test func installerVerifiesSelectedAgentDestination() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = home.appendingPathComponent(".agents/skills/edith-remote-work")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try Data("name: edith-remote-work".utf8).write(
            to: folder.appendingPathComponent("SKILL.md"))
        let installer = SkillInstaller { _, _ in
            CLICommandResult(terminationStatus: 0, output: "done")
        }
        await #expect(throws: SkillsError.self) {
            try await installer.install(
                skill: skill, agentIDs: ["cursor"], home: home, environment: [:])
        }
        let source = try #require(skill.directory).appendingPathComponent("SKILL.md")
        try Data(contentsOf: source).write(to: folder.appendingPathComponent("SKILL.md"))
        try await installer.install(
            skill: skill, agentIDs: ["cursor"], home: home, environment: [:])
    }

    @MainActor @Test func pluginsBelongsOnlyToAgents() throws {
        let entry = try #require(ExtensionRegistry.entry("plugins"))
        #expect(entry.title == "Plugins")
        #expect(entry.suite == .agents)
        #expect(entry.host == .window)
        #expect(MainDestination.plugins.page.parentID == "agents")
    }
}
