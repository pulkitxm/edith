import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Edith
@testable import EdithCore
@testable import EdithKit

@Suite struct SkillsTests {
    private let skill = EdithSkillLibrary.skills[0]
    private static let markdown =
        "---\nname: edith-remote-work\ndescription: Work remotely.\n---\n# Remote work\n\nUse `ed`.\n"

    @Test func documentPreservesCopySourceAndSeparatesMetadata() {
        let document = SkillDocument(markdown: Self.markdown)
        #expect(document.markdown == Self.markdown)
        #expect(document.metadata == "name: edith-remote-work\ndescription: Work remotely.")
        #expect(document.body == "# Remote work\n\nUse `ed`.")
        #expect(SkillDocument(markdown: "# No metadata").body == "# No metadata")
    }

    @Test func githubLoadCachesValidContentAndFallsBackOffline() async throws {
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: cache) }
        let remote = SkillDocumentStore(cacheDirectory: cache) { _ in Data(Self.markdown.utf8) }
        let fresh = try await remote.load(skill)
        #expect(fresh.markdown == Self.markdown)
        #expect(!fresh.isCached)
        let offline = SkillDocumentStore(cacheDirectory: cache) { _ in
            throw URLError(.notConnectedToInternet)
        }
        let saved = try await offline.load(skill)
        #expect(saved.markdown == Self.markdown)
        #expect(saved.isCached)
        let invalid = SkillDocumentStore(cacheDirectory: cache) { _ in Data("not a skill".utf8) }
        #expect(try await invalid.load(skill).markdown == Self.markdown)
    }

    @Test func invalidRemoteContentCannotBecomeAnInstallableSkill() async throws {
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: cache) }
        for text in [
            "<html>Not found</html>", "---\nname: another-skill\n---\n# Wrong skill",
            String(repeating: "a", count: 400_000),
        ] {
            let store = SkillDocumentStore(cacheDirectory: cache) { _ in Data(text.utf8) }
            await #expect(throws: SkillsError.self) { try await store.load(skill) }
        }
        #expect(!FileManager.default.fileExists(atPath: cache.path))
    }

    @Test func markdownHighlightingPreservesSourceAndAddsSyntaxColors() async throws {
        for dark in [false, true] {
            let highlighted = try #require(
                await SyntaxHighlighting.shared.highlight(
                    text: Self.markdown, language: "markdown", dark: dark))
            #expect(highlighted.string == Self.markdown)
            var colors = Set<String>()
            highlighted.enumerateAttribute(
                .foregroundColor, in: NSRange(location: 0, length: highlighted.length)
            ) { value, _, _ in
                if let color = value as? NSColor { colors.insert(color.description) }
            }
            #expect(colors.count > 1)
        }
    }

    @MainActor @Test func markdownViewerAllowsSelectionButNotEditing() throws {
        _ = TestWindowHost.application
        let host = NSHostingView(
            rootView: CodePreview(
                text: Self.markdown, language: "markdown", truncated: false, dark: true))
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        let window = TestWindowHost.window(contentRect: host.frame)
        defer { window.orderOut(nil) }
        window.contentView = host
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        func textView(in view: NSView) -> NSTextView? {
            if let text = view as? NSTextView { return text }
            return view.subviews.lazy.compactMap { textView(in: $0) }.first
        }
        let text = try #require(textView(in: host))
        #expect(!text.isEditable)
        #expect(text.isSelectable)
        #expect(text.string == Self.markdown)
    }

    @MainActor @Test func menuLogosHaveConsistentIntrinsicSizeAndTemplateAppearance() throws {
        for id in [
            "amp", "claude-code", "codex", "command-code", "droid", "mistral-vibe", "warp", "zed",
            "kimi-code-cli",
        ] {
            let image = try #require(SkillBrand.menuImage(for: id))
            #expect(image.size == NSSize(width: 16, height: 16))
            #expect(image.isTemplate == SkillBrand.image(for: id)?.isTemplate)
        }
    }

    @Test func libraryContainsOnlyTheRequestedGitHubSkill() {
        #expect(EdithSkillLibrary.skills.map(\.id) == ["edith-remote-work"])
        #expect(
            skill.sourceURL.absoluteString
                == "https://raw.githubusercontent.com/pulkitxm/edith/main/Packages/Edith/skills/edith-remote-work/SKILL.md"
        )
    }

    @Test func installerTargetsExactlyTheSelectedAgentsWithoutAShell() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data(Self.markdown.utf8).write(to: directory.appendingPathComponent("SKILL.md"))
        let arguments = try SkillInstaller.arguments(
            skill: skill, directory: directory, agentIDs: ["cursor", "claude-code", "cursor"])
        #expect(arguments.suffix(3) == ["--agent", "claude-code", "cursor"])
        #expect(arguments.contains("--global"))
        #expect(arguments.contains("--copy"))
        #expect(arguments.contains(directory.path))
        #expect(!arguments.contains("*"))
        #expect(throws: SkillsError.self) {
            try SkillInstaller.arguments(skill: skill, directory: directory, agentIDs: [])
        }
        #expect(throws: SkillsError.self) {
            try SkillInstaller.arguments(skill: skill, directory: directory, agentIDs: ["unknown"])
        }
        let invalid = EdithSkill(
            id: "../other", name: "Other", summary: "", detail: "", symbol: "terminal")
        #expect(throws: SkillsError.self) {
            try SkillInstaller.arguments(skill: invalid, directory: directory, agentIDs: ["cursor"])
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

    @Test func openClawUsesTheExistingConfigurationRoot() throws {
        let home = URL(fileURLWithPath: "/temporary/home")
        let agent = try #require(SkillAgentCatalog.agents.first { $0.id == "openclaw" })
        let roots = [".openclaw", ".clawdbot", ".moltbot"]
        for root in roots {
            #expect(
                agent.resolvedDirectory(
                    home: home, environment: [:],
                    exists: {
                        $0 == home.appendingPathComponent(root).path
                    }
                ).path == home.appendingPathComponent(root + "/skills").path)
        }
        #expect(
            agent.resolvedDirectory(home: home, environment: [:], exists: { _ in true })
                .path == home.appendingPathComponent(".openclaw/skills").path)
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
            let installer = SkillInstaller(load: { _ in SkillDocument(markdown: Self.markdown) }) {
                request, _ in
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
        let installer = SkillInstaller(load: { _ in SkillDocument(markdown: Self.markdown) }) {
            _, _ in
            CLICommandResult(terminationStatus: 0, output: "done")
        }
        await #expect(throws: SkillsError.self) {
            try await installer.install(
                skill: skill, agentIDs: ["cursor"], home: home, environment: [:])
        }
        try Data(Self.markdown.utf8).write(to: folder.appendingPathComponent("SKILL.md"))
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
