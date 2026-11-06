import EdithExtensionSupport
import Foundation
import Testing

@testable import EdithHostCore

@Suite struct HostMCPAgentConnectionTests {
    private func temporaryHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "mcp-connection-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ text: String, to file: URL) throws {
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
    }

    @Test func statusMapsEveryReportToOneOfTheFourConnections() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        try write(
            "{\"mcpServers\":{\"edith\":{\"command\":\"/app/ed\",\"args\":[\"mcp\"]}}}",
            to: HostMCPClient.cursor.configURL(home: home))
        try write(
            "[mcp_servers.edith]\ncommand = \"/other/ed\"\nargs = [\"mcp\"]\n",
            to: HostMCPClient.codex.configURL(home: home))
        try FileManager.default.createDirectory(
            at: HostMCPClient.vscode.configURL(home: home).deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let installer = HostMCPInstaller(home: home, command: "/app/ed")
        let reports = installer.status()
        #expect(reports.map(\.client) == HostMCPClient.allCases)
        #expect(reports.map(\.connection) == [.manual, .otherEdith, .connected, .notConnected])
        let found = reports.filter(\.clientFound).count
        #expect(found == 4)
        #expect(reports[1].command == "/other/ed")
        #expect(!reports[0].toolFound)

        let withClaude = HostMCPInstaller(
            home: home, command: "/app/ed", tools: ToolRecorder(available: ["claude"]).runner)
        #expect(withClaude.inspect(.claude).toolFound)
        #expect(withClaude.inspect(.claude).connection == .notConnected)

        try write("{\n  // kept\n}\n", to: HostMCPClient.vscode.configURL(home: home))
        #expect(installer.inspect(.vscode).state == .unreadable)
        #expect(installer.inspect(.vscode).connection == .manual)
        #expect(installer.manualStep(.vscode).contains("\"servers\""))
        #expect(installer.manualStep(.claude) == "claude mcp add --scope user edith -- /app/ed mcp")
        #expect(installer.manualStep(.codex).hasPrefix("[mcp_servers.edith]"))
    }

    @Test func connectAllUsesTheSameInstallAsTheCLIAndSkipsMissingClients() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".cursor"), withIntermediateDirectories: true)
        let installer = HostMCPInstaller(home: home, command: "/app/ed")
        let outcomes = installer.install(nil, dryRun: false)
        #expect(outcomes.map(\.action) == [.notFound, .notFound, .created, .notFound])
        #expect(installer.inspect(.cursor).connection == .connected)
        let explicit = installer.install([.vscode], dryRun: false)
        #expect(explicit.map(\.action) == [.created])
        #expect(installer.inspect(.vscode).connection == .connected)
    }

    @Test func disconnectRemovesOnlyEdithFromJSONAndBacksUpFirst() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let file = HostMCPClient.vscode.configURL(home: home)
        let original =
            "{\"inputs\":[],\"servers\":{\"edith\":{\"type\":\"stdio\",\"command\":\"/app/ed\",\"args\":[\"mcp\"]},\"other\":{\"command\":\"o\"}}}"
        try write(original, to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let installer = HostMCPInstaller(home: home, command: "/app/ed")
        let dry = installer.uninstall(.vscode, dryRun: true)
        #expect(dry.action == .removed && !dry.applied && dry.backup == nil)
        #expect(try String(contentsOf: file, encoding: .utf8) == original)

        let removed = installer.uninstall(.vscode, dryRun: false)
        #expect(removed.action == .removed && removed.applied && removed.run == nil)
        let backup = try #require(removed.backup)
        #expect(try String(contentsOf: URL(fileURLWithPath: backup), encoding: .utf8) == original)
        let root = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        #expect((root["inputs"] as? [Any])?.isEmpty == true)
        let servers = try #require(root["servers"] as? [String: Any])
        #expect(servers["edith"] == nil && servers["other"] != nil)
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions]
        #expect((mode as? NSNumber)?.intValue == 0o600)
        #expect(installer.inspect(.vscode).connection == .notConnected)
        #expect(installer.uninstall(.vscode, dryRun: false).action == .unchanged)

        let other = HostMCPInstaller(home: home, command: "/moved/ed")
        try write(
            "{\"mcpServers\":{\"edith\":{\"command\":\"/app/ed\",\"args\":[\"mcp\"]}}}",
            to: HostMCPClient.cursor.configURL(home: home))
        #expect(other.inspect(.cursor).connection == .otherEdith)
        #expect(other.uninstall(.cursor, dryRun: false).applied)
        #expect(other.inspect(.cursor).state == .notRegistered)

        let commented = "{\n  // keep\n  \"mcpServers\": {\"edith\": {}}\n}\n"
        try write(commented, to: HostMCPClient.cursor.configURL(home: home))
        let refused = installer.uninstall(.cursor, dryRun: false)
        #expect(refused.action == .skipped && !refused.applied)
        #expect(refused.note?.contains("not plain JSON") == true)
        #expect(
            try String(contentsOf: HostMCPClient.cursor.configURL(home: home), encoding: .utf8)
                == commented)
    }

    @Test func disconnectCodexPrefersItsCLIAndOtherwiseEditsTheToml() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let file = HostMCPClient.codex.configURL(home: home)
        let config =
            "model = \"x\"\n\n[mcp_servers.edith]\ncommand = \"/app/ed\"\nargs = [\"mcp\"]\n\n[mcp_servers.edith.env]\nA = \"1\"\n\n[mcp_servers.other]\ncommand = \"o\"\n"
        try write(config, to: file)
        let tools = ToolRecorder(available: ["codex"])
        let viaCLI = HostMCPInstaller(home: home, command: "/app/ed", tools: tools.runner)
            .uninstall(.codex, dryRun: false)
        #expect(viaCLI.action == .removed && viaCLI.applied)
        #expect(viaCLI.runLine == "codex mcp remove edith")
        #expect(tools.calls == [["mcp", "remove", "edith"]])
        #expect(try String(contentsOf: file, encoding: .utf8) == config)

        let old = ToolRecorder(available: ["codex"], status: 2, output: "unknown command")
        let fallback = HostMCPInstaller(home: home, command: "/app/ed", tools: old.runner)
            .uninstall(.codex, dryRun: false)
        #expect(fallback.action == .removed && fallback.applied && fallback.run == nil)
        #expect(fallback.backup != nil)
        #expect(
            try String(contentsOf: file, encoding: .utf8)
                == "model = \"x\"\n\n[mcp_servers.other]\ncommand = \"o\"\n")

        try write(
            "model = \"x\"\n\n[mcp_servers.edith]\ncommand = \"/a\"\nargs = [\"mcp\"]\n", to: file)
        _ = HostMCPInstaller(home: home, command: "/app/ed").uninstall(.codex, dryRun: false)
        #expect(try String(contentsOf: file, encoding: .utf8) == "model = \"x\"\n")

        try write("[mcp_servers.edith]\ncommand = \"/a\"\nargs = [\"mcp\"]\n", to: file)
        _ = HostMCPInstaller(home: home, command: "/app/ed").uninstall(.codex, dryRun: false)
        #expect(try String(contentsOf: file, encoding: .utf8) == "")
    }

    @Test func disconnectClaudeOnlyRunsItsCLIAndNeverEditsItsSettings() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let file = HostMCPClient.claude.configURL(home: home)
        let config =
            "{\"projects\":{},\"mcpServers\":{\"edith\":{\"type\":\"stdio\",\"command\":\"/app/ed\",\"args\":[\"mcp\"],\"env\":{}}}}"
        try write(config, to: file)
        let tools = ToolRecorder(available: ["claude"])
        let installer = HostMCPInstaller(home: home, command: "/app/ed", tools: tools.runner)
        let dry = installer.uninstall(.claude, dryRun: true)
        #expect(dry.action == .removed && !dry.applied && tools.calls.isEmpty)
        let removed = installer.uninstall(.claude, dryRun: false)
        #expect(removed.action == .removed && removed.applied && removed.backup == nil)
        #expect(tools.calls == [["mcp", "remove", "--scope", "user", "edith"]])
        #expect(try String(contentsOf: file, encoding: .utf8) == config)

        let failing = ToolRecorder(available: ["claude"], status: 1, output: "no such server\n")
        let refused = HostMCPInstaller(home: home, command: "/app/ed", tools: failing.runner)
            .uninstall(.claude, dryRun: false)
        #expect(refused.action == .skipped && !refused.applied)
        #expect(refused.note?.contains("no such server") == true)

        let manual = HostMCPInstaller(home: home, command: "/app/ed").uninstall(
            .claude, dryRun: false)
        #expect(manual.action == .manual && !manual.applied)
        #expect(manual.runLine == "claude mcp remove --scope user edith")
        #expect(try String(contentsOf: file, encoding: .utf8) == config)
        #expect(!FileManager.default.fileExists(atPath: file.path + ".edith-backup"))
    }

    @Test func uninstallCommandSharesTheInstallerAndReportsEachClient() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let cli = HostMCPSetupCLI(
            home: home, executable: URL(fileURLWithPath: "/app/ed"), codexHome: nil, tools: .none)
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".cursor"), withIntermediateDirectories: true)
        #expect(try cli.execute(["install", "--client", "cursor"]).exitCode == 0)
        let preview = try cli.execute(["uninstall", "--client", "cursor", "--dry-run"])
        #expect(preview.exitCode == 0)
        #expect(preview.stdout.contains("Cursor: would remove Edith from ~/.cursor/mcp.json"))
        let json = try cli.execute(["uninstall", "--client", "all", "--json"])
        #expect(json.exitCode == 0)
        let value = try JSONDecoder().decode(HostCLIJSON.self, from: Data(json.stdout.utf8))
        let actions = value.object?["clients"]?.array?.compactMap {
            $0.object?["action"]?.string
        }
        #expect(actions == ["unchanged", "unchanged", "removed", "unchanged"])
        let again = try cli.execute(["uninstall", "--client", "all"])
        #expect(again.stdout.contains("Edith is not registered with any agent client"))
        let claude = try cli.execute(["uninstall", "--client", "claude"])
        #expect(claude.exitCode == 0)
        #expect(claude.stdout.contains("Claude Code: not registered, nothing to remove"))
        #expect(throws: HostCLIError.self) { try cli.execute(["uninstall"]) }
        #expect(
            !FileManager.default.fileExists(
                atPath: home.appendingPathComponent(".claude.json").path))
    }
}
