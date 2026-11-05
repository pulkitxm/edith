import EdithExtensionSupport
import Foundation
import Testing

@testable import EdithHostCore

@Suite struct HostMCPAgentSetupTests {
    private func temporaryHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "mcp-home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func snippetsMatchEachClientsFormat() throws {
        let command = "/Applications/Edith.app/Contents/MacOS/ed"
        let claude = try #require(
            try JSONSerialization.jsonObject(
                with: Data(HostMCPClient.claude.snippet(command: command).utf8)) as? [String: Any])
        let claudeEntry = try #require(
            (claude["mcpServers"] as? [String: Any])?["edith"] as? [String: Any])
        #expect(claudeEntry["type"] as? String == "stdio")
        #expect(claudeEntry["command"] as? String == command)
        #expect(claudeEntry["args"] as? [String] == ["mcp"])
        let cursor = try #require(
            try JSONSerialization.jsonObject(
                with: Data(HostMCPClient.cursor.snippet(command: command).utf8)) as? [String: Any])
        #expect(
            ((cursor["mcpServers"] as? [String: Any])?["edith"] as? [String: Any])?["type"] == nil)
        let vscode = try #require(
            try JSONSerialization.jsonObject(
                with: Data(HostMCPClient.vscode.snippet(command: command).utf8)) as? [String: Any])
        #expect(
            ((vscode["servers"] as? [String: Any])?["edith"] as? [String: Any])?["type"] as? String
                == "stdio")
        #expect(
            HostMCPClient.codex.snippet(command: command)
                == "[mcp_servers.edith]\ncommand = \"\(command)\"\nargs = [\"mcp\"]\n")
    }

    @Test func configLocationsFollowEachClientsConvention() {
        let home = URL(fileURLWithPath: "/Users/synthetic")
        #expect(HostMCPClient.claude.configURL(home: home).path == "/Users/synthetic/.claude.json")
        #expect(
            HostMCPClient.codex.configURL(home: home).path == "/Users/synthetic/.codex/config.toml")
        #expect(
            HostMCPClient.codex.configURL(home: home, codexHome: "/elsewhere").path
                == "/elsewhere/config.toml")
        #expect(
            HostMCPClient.cursor.configURL(home: home).path == "/Users/synthetic/.cursor/mcp.json")
        #expect(
            HostMCPClient.vscode.configURL(home: home).path
                == "/Users/synthetic/Library/Application Support/Code/User/mcp.json")
    }

    @Test func jsonInstallMergesKeepsOtherServersAndBacksUp() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let file = HostMCPClient.claude.configURL(home: home)
        try Data("{\"theme\":\"dark\",\"mcpServers\":{\"other\":{\"command\":\"x\"}}}".utf8)
            .write(to: file)
        let installer = HostMCPInstaller(home: home, command: "/app/ed")
        let dry = installer.install(.claude, dryRun: true)
        #expect(dry.action == .updated && !dry.applied)
        #expect(installer.inspect(.claude).state == .notRegistered)
        let applied = installer.install(.claude, dryRun: false)
        #expect(applied.applied)
        #expect(applied.backup != nil)
        let root = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        #expect(root["theme"] as? String == "dark")
        let servers = try #require(root["mcpServers"] as? [String: Any])
        #expect(servers["other"] != nil && servers["edith"] != nil)
        #expect(installer.inspect(.claude).state == .registered)
        #expect(installer.install(.claude, dryRun: false).action == .unchanged)
        let moved = HostMCPInstaller(home: home, command: "/moved/ed")
        #expect(moved.inspect(.claude).state == .outdated)
        #expect(moved.install(.claude, dryRun: false).action == .updated)
        #expect(moved.inspect(.claude).command == "/moved/ed")
    }

    @Test func missingConfigIsCreatedAndUnparseableConfigIsLeftAlone() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let installer = HostMCPInstaller(home: home, command: "/app/ed")
        let created = installer.install(.cursor, dryRun: false)
        #expect(created.action == .created && created.applied)
        #expect(installer.inspect(.cursor).state == .registered)
        let file = HostMCPClient.vscode.configURL(home: home)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let commented = "{\n  // keep\n  \"servers\": {}\n}\n"
        try Data(commented.utf8).write(to: file)
        let skipped = installer.install(.vscode, dryRun: false)
        #expect(skipped.action == .skipped && !skipped.applied)
        #expect(skipped.snippet.contains("\"servers\""))
        #expect(try String(contentsOf: file, encoding: .utf8) == commented)
        #expect(installer.inspect(.vscode).state == .unreadable)
    }

    @Test func tomlInstallAppendsReplacesAndRefusesMultilineArgs() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let file = HostMCPClient.codex.configURL(home: home)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("model = \"x\"\n\n[mcp_servers.other]\ncommand = \"o\"\n".utf8).write(to: file)
        let installer = HostMCPInstaller(home: home, command: "/app/ed")
        #expect(installer.install(.codex, dryRun: false).applied)
        var text = try String(contentsOf: file, encoding: .utf8)
        #expect(text.contains("model = \"x\"") && text.contains("[mcp_servers.other]"))
        #expect(text.contains("[mcp_servers.edith]\ncommand = \"/app/ed\"\nargs = [\"mcp\"]"))
        #expect(installer.inspect(.codex).state == .registered)
        #expect(installer.install(.codex, dryRun: false).action == .unchanged)
        let moved = HostMCPInstaller(home: home, command: "/moved/ed")
        #expect(moved.inspect(.codex).state == .outdated)
        #expect(moved.install(.codex, dryRun: false).applied)
        text = try String(contentsOf: file, encoding: .utf8)
        #expect(text.components(separatedBy: "[mcp_servers.edith]").count == 2)
        #expect(text.contains("command = \"/moved/ed\"") && !text.contains("\"/app/ed\""))
        #expect(text.contains("[mcp_servers.other]\ncommand = \"o\""))
        try Data("[mcp_servers.edith]\ncommand = \"/a\"\nargs = [\n  \"mcp\",\n]\n".utf8)
            .write(to: file)
        let skipped = moved.install(.codex, dryRun: false)
        #expect(skipped.action == .skipped)
    }

    @Test func setupCLIReportsStatusAndInstallsWithDryRunAndJSON() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let cli = HostMCPSetupCLI(
            home: home, executable: URL(fileURLWithPath: "/app/ed"), codexHome: nil)
        let dry = try cli.execute(["install", "--client", "all", "--dry-run", "--json"])
        let preview = try JSONDecoder().decode(
            HostCLIJSON.self, from: Data(dry.stdout.utf8))
        #expect(preview.object?["dryRun"] == .bool(true))
        #expect(preview.object?["clients"]?.array?.count == 4)
        #expect(
            !FileManager.default.fileExists(atPath: home.appendingPathComponent(".cursor").path))
        let applied = try cli.execute(["install", "--client", "cursor"])
        #expect(applied.exitCode == 0 && applied.stdout.contains("added Edith"))
        let status = try cli.execute(["status", "--json"])
        let states = try JSONDecoder().decode(HostCLIJSON.self, from: Data(status.stdout.utf8))
            .object?["clients"]?.array?.compactMap {
                $0.object.flatMap { ($0["client"]?.string, $0["state"]?.string) }
            }
        #expect(states?.first { $0.0 == "cursor" }?.1 == "registered")
        #expect(states?.first { $0.0 == "claude" }?.1 == "notRegistered")
        #expect(throws: HostCLIError.self) { try cli.execute(["install"]) }
        #expect(throws: HostCLIError.self) { try cli.execute(["install", "--client", "emacs"]) }
        #expect(throws: HostCLIError.self) {
            try cli.execute(["install", "--client", "claude", "--command", "relative/ed"])
        }
    }

    @Test func initializeAdvertisesListChangedResourcesAndStartInstructions() async throws {
        let fixture = AgentFixture()
        let output = AgentOutput()
        let server = fixture.server(output)
        try await fixture.initialize(server, output)
        let result = try await output.response(1).object?["result"]?.object
        let capabilities = result?["capabilities"]?.object
        #expect(capabilities?["tools"]?.object?["listChanged"] == .bool(true))
        #expect(capabilities?["resources"] != nil)
        let instructions = result?["instructions"]?.string ?? ""
        #expect(instructions.contains("edith_catalog"))
        #expect(instructions.contains("edith_extensions_install"))
        await server.shutdown()
    }

    @Test func resourcesExposeGuideTopicsAndPerExtensionGuides() async throws {
        let fixture = AgentFixture()
        let output = AgentOutput()
        let server = fixture.server(output)
        try await fixture.initialize(server, output)
        try await server.accept(
            Data("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"resources/list\"}".utf8))
        let uris = try await output.response(2).object?["result"]?.object?["resources"]?.array?
            .compactMap { $0.object?["uri"]?.string }
        #expect(
            uris == [
                "edith://guide", "edith://guide/agent", "edith://guide/mcp",
                "edith://extensions/emoji",
                "edith://extensions/music",
            ])
        try await server.accept(
            Data(
                "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"resources/read\",\"params\":{\"uri\":\"edith://extensions/emoji\"}}"
                    .utf8))
        let text = try await output.response(3).object?["result"]?.object?["contents"]?.array?
            .first?.object?["text"]?.string
        #expect(text?.contains("# Emoji Picker") == true)
        #expect(text?.contains("Find any emoji fast") == true)
        #expect(text?.contains("1. **Open the picker**: Press the hotkey.") == true)
        #expect(text?.contains("`ed emoji pick`") == true)
        try await server.accept(
            Data(
                "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"resources/read\",\"params\":{\"uri\":\"edith://guide\"}}"
                    .utf8))
        let guide = try await output.response(4).object?["result"]?.object?["contents"]?.array?
            .first?.object?["text"]?.string
        #expect(guide == HostGuideCLI.text)
        try await server.accept(
            Data(
                "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"resources/read\",\"params\":{\"uri\":\"edith://nothing\"}}"
                    .utf8))
        #expect(try await output.response(5).object?["error"] != nil)
        await server.shutdown()
    }

    @Test func catalogToolMergesInstallStateWithGuides() async throws {
        let fixture = AgentFixture()
        let output = AgentOutput()
        let server = fixture.server(output)
        try await fixture.initialize(server, output)
        func call(_ id: Int, _ arguments: String) async throws -> [String: HostCLIJSON]? {
            try await server.accept(
                Data(
                    "{\"jsonrpc\":\"2.0\",\"id\":\(id),\"method\":\"tools/call\",\"params\":{\"name\":\"edith_catalog\",\"arguments\":\(arguments)}}"
                        .utf8))
            return try await output.response(Int64(id)).object?["result"]?.object?[
                "structuredContent"]?.object
        }
        let all = try await call(2, "{}")
        let entries = all?["extensions"]?.array?.compactMap(\.object)
        #expect(entries?.map { $0["id"]?.string } == ["emoji", "music"])
        #expect(entries?.first?["status"]?.string == "available")
        #expect(entries?.last?["status"]?.string == "enabled")
        #expect(entries?.first?["tagline"]?.string == "Find any emoji fast")
        #expect(entries?.first?["examples"] == .strings(["ed emoji pick"]))
        let available = try await call(3, "{\"status\":\"available\"}")
        #expect(available?["extensions"]?.array?.count == 1)
        let searched = try await call(4, "{\"query\":\"music player\"}")
        #expect(searched?["extensions"]?.array?.first?.object?["id"]?.string == "music")
        let one = try await call(5, "{\"id\":\"emoji\"}")
        #expect(
            one?["extensions"]?.array?.first?.object?["steps"]?.array?.first?.object?["title"]
                == .string("Open the picker"))
        try await server.accept(
            Data(
                "{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"tools/call\",\"params\":{\"name\":\"edith_catalog\",\"arguments\":{\"id\":\"missing\"}}}"
                    .utf8))
        #expect(try await output.response(6).object?["error"] != nil)
        await server.shutdown()
    }

    @Test func installPreviewsUntilConfirmedThenAnnouncesNewTools() async throws {
        let fixture = AgentFixture()
        let output = AgentOutput()
        let server = fixture.server(output)
        try await fixture.initialize(server, output)
        try await server.accept(
            Data("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}".utf8))
        let first = try await output.response(2).object?["result"]?.object?["tools"]?.array?
            .compactMap { $0.object?["name"]?.string }
        #expect(first == ["edith_catalog", "edith_extensions_install", "edith_music_play"])
        let install = try await output.response(2).object?["result"]?.object?["tools"]?.array?
            .first { $0.object?["name"] == .string("edith_extensions_install") }
        #expect(install?.object?["inputSchema"]?.object?["properties"]?.object?["confirm"] != nil)
        try await server.accept(
            Data(
                "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"edith_extensions_install\",\"arguments\":{\"arguments\":[\"emoji\"]}}}"
                    .utf8))
        let preview = try await output.response(3).object?["result"]?.object
        #expect(
            preview?["content"]?.array?.first?.object?["text"]?.string?.contains(
                "requiresConfirmation") == true)
        #expect(await fixture.coreCalls().isEmpty)
        #expect(await !output.hasNotification("notifications/tools/list_changed"))
        try await server.accept(
            Data(
                "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"name\":\"edith_extensions_install\",\"arguments\":{\"arguments\":[\"emoji\"],\"confirm\":true}}}"
                    .utf8))
        #expect(try await output.response(4).object?["result"]?.object?["isError"] == .bool(false))
        #expect(await fixture.coreCalls() == [["extensions", "install", "--json", "emoji"]])
        try await output.waitForNotification("notifications/tools/list_changed")
        try await server.accept(
            Data("{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"tools/list\"}".utf8))
        let after = try await output.response(5).object?["result"]?.object?["tools"]?.array?
            .compactMap { $0.object?["name"]?.string }
        #expect(
            after == [
                "edith_catalog", "edith_emoji_pick", "edith_extensions_install", "edith_music_play",
            ])
        await server.shutdown()
    }

    @Test func noNotificationBeforeToolsWereListedOrWhenNothingChanged() async throws {
        let fixture = AgentFixture(installed: true)
        let output = AgentOutput()
        let server = fixture.server(output)
        try await fixture.initialize(server, output)
        try await server.accept(
            Data(
                "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"edith_extensions_install\",\"arguments\":{\"arguments\":[\"emoji\"],\"confirm\":true}}}"
                    .utf8))
        _ = try await output.response(2)
        try await server.accept(
            Data("{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/list\"}".utf8))
        _ = try await output.response(3)
        try await server.accept(
            Data(
                "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"name\":\"edith_extensions_install\",\"arguments\":{\"arguments\":[\"emoji\"],\"confirm\":true}}}"
                    .utf8))
        _ = try await output.response(4)
        #expect(await !output.hasNotification("notifications/tools/list_changed"))
        await server.shutdown()
    }
}

private actor AgentOutput {
    private var values: [HostCLIJSON] = []
    func append(_ data: Data) throws {
        values.append(try JSONDecoder().decode(HostCLIJSON.self, from: data))
    }
    func hasNotification(_ method: String) -> Bool {
        values.contains { $0.object?["method"] == .string(method) }
    }
    func waitForNotification(_ method: String) async throws {
        for _ in 0..<200 {
            if hasNotification(method) { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw HostCLIError.timedOut
    }
    func response(_ id: Int64) async throws -> HostCLIJSON {
        for _ in 0..<200 {
            if let value = values.first(where: { $0.object?["id"] == .integer(id) }) {
                return value
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw HostCLIError.timedOut
    }
}

private actor AgentState {
    var installed: Bool
    private(set) var calls: [[String]] = []
    init(installed: Bool) { self.installed = installed }
    func record(_ arguments: [String]) { calls.append(arguments); installed = true }
}

private struct AgentFixture: Sendable {
    let state: AgentState

    init(installed: Bool = false) { state = AgentState(installed: installed) }

    func coreCalls() async -> [[String]] { await state.calls }

    static let index = [
        HostExtension(
            id: "music", title: "Music", symbolName: "music.note", category: "media",
            commands: ["music"],
            guide: HostExtensionGuide(
                tagline: "Control playback", summary: "A music player for the menu bar.",
                steps: [], examples: ["ed music play"])),
        HostExtension(
            id: "emoji", title: "Emoji Picker", symbolName: "face.smiling",
            category: "productivity",
            commands: ["emoji"],
            guide: HostExtensionGuide(
                tagline: "Find any emoji fast", summary: "Pick emoji anywhere.",
                steps: [
                    HostGuideStep(
                        symbolName: "keyboard", title: "Open the picker",
                        detail: "Press the hotkey.")
                ], examples: ["ed emoji pick"])),
    ]

    func initialize(_ server: HostMCPCLI, _ output: AgentOutput) async throws {
        try await server.accept(
            Data(
                "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-11-25\",\"clientInfo\":{\"name\":\"fixture\",\"version\":\"1\"},\"capabilities\":{}}}"
                    .utf8))
        try await server.accept(
            Data("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}".utf8))
    }

    func server(_ output: AgentOutput) -> HostMCPCLI {
        let state = state
        return HostMCPCLI(
            version: "1",
            invoke: { request in
                let installed = await state.installed
                if request.action == .ls {
                    let items: [HostCLIJSON] = [
                        .object([
                            "id": .string("music"), "installed": .bool(true),
                            "compatible": .bool(true), "enabled": .bool(true),
                            "running": .bool(true), "version": .string("1"),
                            "disablePending": .bool(false), "removalPending": .bool(false),
                        ]),
                        .object([
                            "id": .string("emoji"), "installed": .bool(installed),
                            "compatible": .bool(true), "enabled": .bool(installed),
                            "running": .bool(installed), "version": .string("1"),
                            "disablePending": .bool(false), "removalPending": .bool(false),
                        ]),
                    ]
                    return try HostCLIJSON.array(items).encoded()
                }
                switch (request.id, request.operation) {
                case ("host", "host.cli.catalog"):
                    return try JSONEncoder().encode(
                        HostCLIProviderCatalog(
                            owner: "host",
                            commands: [
                                .init(
                                    route: ["extensions", "install"], operation: "host.cli",
                                    summary: "Download one compatible extension and start it.")
                            ]))
                case ("music", "music.cli.catalog"):
                    return try JSONEncoder().encode(
                        HostCLIProviderCatalog(
                            owner: "music",
                            commands: [
                                .init(
                                    route: ["music", "play"], operation: "music.cli",
                                    summary: "Play")
                            ]))
                case ("emoji", "emoji.cli.catalog"):
                    return try JSONEncoder().encode(
                        HostCLIProviderCatalog(
                            owner: "emoji",
                            commands: [
                                .init(
                                    route: ["emoji", "pick"], operation: "emoji.cli",
                                    summary: "Pick an emoji")
                            ]))
                default: throw HostCLIError.rejected("Unsupported fixture operation")
                }
            }, send: { try await output.append($0) },
            coreExecute: { arguments, _ in
                await state.record(arguments)
                return try ExtensionCLIReply(stdout: "{}\n", stderr: "", exitCode: 0)
            }, index: { Self.index })
    }
}
