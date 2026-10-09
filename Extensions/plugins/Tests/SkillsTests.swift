import Foundation
import Testing
import EdithExtensionSupport
@testable import PluginsExtension

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

    @MainActor @Test func githubLoadCachesValidContentAndFallsBackOffline() async throws {
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

    @MainActor @Test func reopeningRefreshesMarkdownAndMarksOfflineFallback() async throws {
        actor Remote {
            var value = 0
            func fetch() throws -> Data {
                value += 1
                if value == 3 { throw URLError(.notConnectedToInternet) }
                return Data((SkillsTests.markdown + "\nRevision \(value)\n").utf8)
            }
        }
        let remote = Remote()
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: cache) }
        let store = SkillDocumentStore(cacheDirectory: cache) { _ in
            try await remote.fetch()
        }
        #expect(store.cachedDocument(for: skill) == nil)
        let first = try await store.load(skill)
        #expect(store.cachedDocument(for: skill)?.isCached == true)
        let second = try await store.load(skill)
        #expect(second.markdown != first.markdown)
        #expect(second.markdown.hasSuffix("Revision 2\n"))
        #expect(!second.isCached)
        let offline = try await store.load(skill)
        #expect(offline.markdown == second.markdown)
        #expect(offline.isCached)
        #expect(await remote.value == 3)
    }

    @MainActor @Test func invalidRemoteContentCannotBecomeAnInstallableSkill() async throws {
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

    @Test func libraryContainsTheBundledGitHubSkills() {
        #expect(
            EdithSkillLibrary.skills.map(\.id) == [
                "edith-remote-work", "edith-video-edit", "edith-video-delivery", "edith-latex-edit",
            ])
        #expect(
            skill.sourceURL.absoluteString
                == "https://raw.githubusercontent.com/pulkitxm/edith/main/Packages/Edith/skills/edith-remote-work/SKILL.md"
        )
    }

    @MainActor @Test func bundledCatalogDocumentsLoadForPreviewWithoutInstallation() async throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("../Packages/Edith/skills")
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: cache) }
        let store = SkillDocumentStore(cacheDirectory: cache) { url in
            let id = url.deletingLastPathComponent().lastPathComponent
            return try Data(contentsOf: root.appendingPathComponent(id + "/SKILL.md"))
        }
        for entry in EdithSkillLibrary.skills {
            let document = try await store.load(entry)
            #expect(document.metadata.contains("name: " + entry.id))
            #expect(!document.body.isEmpty)
            #expect(!document.isCached)
        }
        let offline = SkillDocumentStore(cacheDirectory: cache) { _ in
            throw URLError(.notConnectedToInternet)
        }
        for entry in EdithSkillLibrary.skills {
            #expect(try await offline.load(entry).isCached)
        }
    }

    @Test func installerTargetsExactlyTheSelectedAgentsWithoutAShell() throws {
        let arguments = try SkillInstaller.arguments(
            skill: skill, agentIDs: ["cursor", "claude-code", "cursor"])
        #expect(arguments.suffix(3) == ["--agent", "claude-code", "cursor"])
        #expect(arguments.contains("--global"))
        #expect(arguments.contains("--copy"))
        #expect(arguments.contains(skill.packageURL.absoluteString))
        #expect(
            skill.packageURL.path
                == "/pulkitxm/edith/tree/main/Packages/Edith/skills/edith-remote-work")
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

    @Test func installerDoesNotReportSuccessOnFailedOrMissingFiles() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        for status: Int32 in [1, 0] {
            let installer = SkillInstaller(recordInstalled: { _, _ in }) {
                request, _ in
                #expect(request.executableURL.path == "/usr/bin/env")
                #expect(request.arguments.first == "npx")
                #expect(request.terminatesProcessGroup)
                #expect(request.timeout == 300)
                #expect(request.environment["HOME"] == home.path)
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
        let installer = SkillInstaller(recordInstalled: { _, _ in }) {
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

    @MainActor @Test func completeInstallRefreshesPreviewAndSharedTargets() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let store = SkillDocumentStore(cacheDirectory: home.appendingPathComponent("cache")) { _ in
            throw URLError(.notConnectedToInternet)
        }
        try store.recordInstalled(SkillDocument(markdown: Self.markdown), for: skill)
        let latest = Self.markdown + "\n[Blueprint](references/guide.md)\n"
        let packageURL = skill.packageURL.absoluteString
        let installer = SkillInstaller(recordInstalled: { skill, document in
            try await store.recordInstalled(document, for: skill)
        }) { request, _ in
            #expect(request.arguments.contains("skills@1.5.24"))
            #expect(request.arguments.contains(packageURL))
            let folder = home.appendingPathComponent(".agents/skills/edith-remote-work")
            try FileManager.default.createDirectory(
                at: folder.appendingPathComponent("references/nested"),
                withIntermediateDirectories: true)
            try Data(latest.utf8).write(to: folder.appendingPathComponent("SKILL.md"))
            try Data("[Details](nested/details.md)".utf8)
                .write(to: folder.appendingPathComponent("references/guide.md"))
            try Data("Synthetic details".utf8)
                .write(to: folder.appendingPathComponent("references/nested/details.md"))
            return CLICommandResult(terminationStatus: 0, output: "done")
        }
        try await installer.install(
            skill: skill, agentIDs: ["cursor", "opencode"], home: home, environment: [:])
        #expect(store.cachedDocument(for: skill)?.markdown == latest)
        let preview = try await store.load(skill)
        #expect(preview.markdown == latest)
        #expect(preview.isCached)
    }

    @Test func missingNestedReferenceRejectsSuccessfulInstallerExit() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let installer = SkillInstaller(recordInstalled: { _, _ in
            Issue.record("Incomplete packages must not refresh the preview.")
        }) { _, _ in
            let folder = home.appendingPathComponent(".agents/skills/edith-remote-work")
            try FileManager.default.createDirectory(
                at: folder.appendingPathComponent("references"),
                withIntermediateDirectories: true)
            try Data((Self.markdown + "\n[Blueprint](references/guide.md)").utf8)
                .write(to: folder.appendingPathComponent("SKILL.md"))
            try Data("[Missing](nested/missing.md)".utf8)
                .write(to: folder.appendingPathComponent("references/guide.md"))
            return CLICommandResult(terminationStatus: 0, output: "done")
        }
        await #expect(throws: SkillsError.self) {
            try await installer.install(
                skill: skill, agentIDs: ["opencode"], home: home, environment: [:])
        }
    }

    @Test func differentAgentPackagesCannotReportInstallationSuccess() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let installer = SkillInstaller(recordInstalled: { _, _ in
            Issue.record("Mismatched packages must not refresh the preview.")
        }) { _, _ in
            for (directory, content) in [
                (".agents/skills", "Synthetic reference one"),
                (".pi/agent/skills", "Synthetic reference two"),
            ] {
                let folder = home.appendingPathComponent(directory + "/edith-remote-work")
                try FileManager.default.createDirectory(
                    at: folder.appendingPathComponent("references"),
                    withIntermediateDirectories: true)
                try Data((Self.markdown + "\n[Guide](references/guide.md)").utf8)
                    .write(to: folder.appendingPathComponent("SKILL.md"))
                try Data(content.utf8)
                    .write(to: folder.appendingPathComponent("references/guide.md"))
            }
            return CLICommandResult(terminationStatus: 0, output: "done")
        }
        await #expect(throws: SkillsError.self) {
            try await installer.install(
                skill: skill, agentIDs: ["cursor", "pi"], home: home, environment: [:])
        }
    }

    @Test func packageReferencesCannotEscapeTheirInstalledDirectory() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        for link in ["../outside.md", "references/outside.md"] {
            let installer = SkillInstaller(recordInstalled: { _, _ in }) { _, _ in
                let folder = home.appendingPathComponent(".agents/skills/edith-remote-work")
                try FileManager.default.createDirectory(
                    at: folder.appendingPathComponent("references"),
                    withIntermediateDirectories: true)
                try Data((Self.markdown + "\n[Outside](\(link))").utf8)
                    .write(to: folder.appendingPathComponent("SKILL.md"))
                let outside = home.appendingPathComponent(".agents/skills/outside.md")
                try Data("Outside".utf8).write(to: outside)
                if link.hasPrefix("references/") {
                    try FileManager.default.createSymbolicLink(
                        at: folder.appendingPathComponent(link), withDestinationURL: outside)
                }
                return CLICommandResult(terminationStatus: 0, output: "done")
            }
            await #expect(throws: SkillsError.self) {
                try await installer.install(
                    skill: skill, agentIDs: ["cursor"], home: home, environment: [:])
            }
        }
    }

}
