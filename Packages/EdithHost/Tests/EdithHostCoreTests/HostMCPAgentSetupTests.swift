import Darwin
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

    private func makeDirectory(_ home: URL, _ path: String) throws {
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(path), withIntermediateDirectories: true)
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
        #expect(HostMCPClient.cursor.snippet(command: command).hasPrefix("{\n  \"mcpServers\": {\n"))
    }

    @Test func unreachableEdithIsAnInternalErrorWithItsMessage() async throws {
        let output = AgentOutput()
        let server = HostMCPCLI(
            version: "1", invoke: { _ in throw HostCLIError.unavailable },
            send: { try await output.append($0) }, index: { [] })
        try await AgentFixture().initialize(server, output)
        try await server.accept(
            Data("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}".utf8))
        let failure = try await output.response(2).object?["error"]?.object
        #expect(failure?["code"] == .integer(-32603))
        #expect(failure?["message"]?.string?.contains("Edith is not running") == true)
        await server.shutdown()
    }

    @Test func registrationCommandsMatchEachClientsCLI() {
        #expect(
            HostMCPClient.claude.registerArguments(command: "/app/ed")
                == ["mcp", "add", "--scope", "user", "edith", "--", "/app/ed", "mcp"])
        #expect(
            HostMCPClient.claude.unregisterArguments == ["mcp", "remove", "--scope", "user", "edith"])
        #expect(
            HostMCPClient.codex.registerArguments(command: "/app/ed")
                == ["mcp", "add", "edith", "--", "/app/ed", "mcp"])
        #expect(HostMCPClient.cursor.registrationTool == nil)
        #expect(HostMCPClient.vscode.registrationTool == nil)
        #expect(
            HostMCPClient.shellLine(["claude", "--", "/Volumes/My Disk/Edith.app/ed", "it's"])
                == "claude -- '/Volumes/My Disk/Edith.app/ed' 'it'\\''s'")
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

    @Test func claudeIsRegisteredThroughItsOwnCLIAndItsConfigIsNeverRewritten() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let tools = ToolRecorder(available: ["claude"])
        let installer = HostMCPInstaller(home: home, command: "/app/ed", tools: tools.runner)
        let dry = installer.install(.claude, dryRun: true)
        #expect(dry.action == .created && !dry.applied)
        #expect(dry.runLine == "claude mcp add --scope user edith -- /app/ed mcp")
        #expect(tools.calls.isEmpty)
        let added = installer.install(.claude, dryRun: false)
        #expect(added.action == .created && added.applied)
        #expect(tools.calls == [["mcp", "add", "--scope", "user", "edith", "--", "/app/ed", "mcp"]])
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent(".claude.json").path))

        let config = "{\"projects\":{},\"mcpServers\":{\"edith\":{\"type\":\"stdio\",\"command\":\"/old/ed\",\"args\":[\"mcp\"],\"env\":{}}}}"
        try Data(config.utf8).write(to: home.appendingPathComponent(".claude.json"))
        tools.reset()
        #expect(installer.inspect(.claude).state == .outdated)
        let moved = installer.install(.claude, dryRun: false)
        #expect(moved.action == .updated && moved.applied)
        #expect(
            tools.calls == [
                ["mcp", "remove", "--scope", "user", "edith"],
                ["mcp", "add", "--scope", "user", "edith", "--", "/app/ed", "mcp"],
            ])
        #expect(try String(contentsOf: home.appendingPathComponent(".claude.json"), encoding: .utf8) == config)

        tools.reset()
        let current = HostMCPInstaller(home: home, command: "/old/ed", tools: tools.runner)
        #expect(current.install(.claude, dryRun: false).action == .unchanged)
        #expect(tools.calls.isEmpty)

        let failing = ToolRecorder(available: ["claude"], status: 1, output: "MCP server edith already exists\n")
        let refused = HostMCPInstaller(home: home, command: "/app/ed", tools: failing.runner)
            .install(.claude, dryRun: false)
        #expect(refused.action == .skipped && !refused.applied)
        #expect(refused.note?.contains("MCP server edith already exists") == true)
    }

    @Test func claudeWithoutItsCLIPrintsTheCommandInsteadOfEditingFiles() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let installer = HostMCPInstaller(home: home, command: "/app/ed")
        let outcome = installer.install(.claude, dryRun: false)
        #expect(outcome.action == .manual && !outcome.applied)
        #expect(outcome.runLine == "claude mcp add --scope user edith -- /app/ed mcp")
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent(".claude.json").path))
        let cli = HostMCPSetupCLI(
            home: home, executable: URL(fileURLWithPath: "/app/ed"), codexHome: nil, tools: .none)
        let explicit = try cli.execute(["install", "--client", "claude"])
        #expect(explicit.exitCode == 1)
        #expect(explicit.stdout.contains("claude mcp add --scope user edith -- /app/ed mcp"))
        try makeDirectory(home, ".claude")
        let all = try cli.execute(["install", "--client", "all"])
        #expect(all.exitCode == 0)
        #expect(all.stdout.contains("Once Claude Code is installed, run:"))
    }

    @Test func codexPrefersItsCLIAndFallsBackToConfigToml() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let tools = ToolRecorder(available: ["codex"])
        let viaCLI = HostMCPInstaller(home: home, command: "/app/ed", tools: tools.runner)
            .install(.codex, dryRun: false)
        #expect(viaCLI.applied && viaCLI.runLine == "codex mcp add edith -- /app/ed mcp")
        #expect(tools.calls == [["mcp", "add", "edith", "--", "/app/ed", "mcp"]])
        let old = ToolRecorder(available: ["codex"], status: 2, output: "unrecognized subcommand 'mcp'")
        let fallback = HostMCPInstaller(home: home, command: "/app/ed", tools: old.runner)
            .install(.codex, dryRun: false)
        #expect(fallback.applied && fallback.run == nil)
        let text = try String(
            contentsOf: HostMCPClient.codex.configURL(home: home), encoding: .utf8)
        #expect(text == "[mcp_servers.edith]\ncommand = \"/app/ed\"\nargs = [\"mcp\"]\n")
    }

    @Test func systemRunnerRunsTheClientsRealExecutable() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let bin = home.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let log = home.appendingPathComponent("calls.txt")
        let script = bin.appendingPathComponent("claude")
        try Data("#!/bin/sh\nprintf '%s\\n' \"$*\" >> '\(log.path)'\necho added\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let runner = HostMCPToolRunner.system(home: home, path: [bin.path])
        #expect(runner.locate("claude")?.path == script.path)
        let outcome = HostMCPInstaller(home: home, command: "/app/ed", tools: runner)
            .install(.claude, dryRun: false)
        #expect(outcome.applied)
        #expect(
            try String(contentsOf: log, encoding: .utf8)
                == "mcp add --scope user edith -- /app/ed mcp\n")
    }

    @Test func jsonInstallMergesKeepsOtherServersAndBacksUp() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let file = HostMCPClient.cursor.configURL(home: home)
        try makeDirectory(home, ".cursor")
        try Data("{\"theme\":\"dark\",\"mcpServers\":{\"other\":{\"command\":\"x\"}}}".utf8)
            .write(to: file)
        let installer = HostMCPInstaller(home: home, command: "/app/ed")
        let dry = installer.install(.cursor, dryRun: true)
        #expect(dry.action == .updated && !dry.applied)
        #expect(installer.inspect(.cursor).state == .notRegistered)
        let applied = installer.install(.cursor, dryRun: false)
        #expect(applied.applied)
        #expect(applied.backup != nil)
        let root = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        #expect(root["theme"] as? String == "dark")
        let servers = try #require(root["mcpServers"] as? [String: Any])
        #expect(servers["other"] != nil && servers["edith"] != nil)
        #expect(installer.inspect(.cursor).state == .registered)
        #expect(installer.install(.cursor, dryRun: false).action == .unchanged)
        let moved = HostMCPInstaller(home: home, command: "/moved/ed")
        #expect(moved.inspect(.cursor).state == .outdated)
        #expect(moved.install(.cursor, dryRun: false).action == .updated)
        #expect(moved.inspect(.cursor).command == "/moved/ed")
        try Data("{\"mcpServers\":{\"edith\":{\"command\":\"/moved/ed\",\"args\":[\"serve\"]}}}".utf8)
            .write(to: file)
        #expect(moved.inspect(.cursor).state == .outdated)
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

    @Test func installAllTouchesOnlyClientsFoundOnThisMac() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try makeDirectory(home, ".cursor")
        let cli = HostMCPSetupCLI(
            home: home, executable: URL(fileURLWithPath: "/app/ed"), codexHome: nil, tools: .none)
        let dry = try cli.execute(["install", "--client", "all", "--dry-run", "--json"])
        let preview = try JSONDecoder().decode(HostCLIJSON.self, from: Data(dry.stdout.utf8))
        #expect(preview.object?["dryRun"] == .bool(true))
        let actions = preview.object?["clients"]?.array?.compactMap {
            $0.object.flatMap { ($0["client"]?.string ?? "", $0["action"]?.string ?? "") }
        }
        #expect(actions?.map(\.0) == ["claude", "codex", "cursor", "vscode"])
        #expect(actions?.map(\.1) == ["notFound", "notFound", "created", "notFound"])
        #expect(dry.exitCode == 0)
        #expect(!FileManager.default.fileExists(atPath: HostMCPClient.cursor.configURL(home: home).path))
        let applied = try cli.execute(["install", "--client", "all"])
        #expect(applied.exitCode == 0)
        #expect(applied.stdout.contains("Cursor: added Edith to ~/.cursor/mcp.json"))
        #expect(applied.stdout.contains("VS Code: not found on this Mac, skipped"))
        #expect(applied.stdout.contains("Restart Cursor to load Edith, then ask the agent to call edith_catalog."))
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent("Library").path))
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent(".codex").path))
    }

    @Test func setupCLIReportsStatusWithOneNextStep() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let cli = HostMCPSetupCLI(
            home: home, executable: URL(fileURLWithPath: "/app/ed"), codexHome: nil, tools: .none)
        #expect(try cli.execute(["status"]).stdout.contains("No agent client was found on this Mac."))
        try makeDirectory(home, ".cursor")
        try makeDirectory(home, ".codex")
        let pending = try cli.execute(["status"]).stdout
        #expect(pending.contains("cursor  not registered"))
        #expect(pending.contains("vscode  client not found"))
        #expect(pending.contains("Run ed mcp install --client all to register Edith with every client found."))
        _ = try cli.execute(["install", "--client", "cursor"])
        #expect(
            try cli.execute(["status"]).stdout.contains(
                "Run ed mcp install --client codex to register Edith."))
        _ = try cli.execute(["install", "--client", "codex"])
        let done = try cli.execute(["status", "--json"])
        let states = try JSONDecoder().decode(HostCLIJSON.self, from: Data(done.stdout.utf8))
            .object?["clients"]?.array?.compactMap {
                $0.object.flatMap { ($0["client"]?.string, $0["state"]?.string, $0["clientFound"]?.bool) }
            }
        #expect(states?.first { $0.0 == "cursor" }?.1 == "registered")
        #expect(states?.first { $0.0 == "claude" }?.1 == "notRegistered")
        #expect(states?.first { $0.0 == "claude" }?.2 == false)
        #expect(
            try cli.execute(["status"]).stdout.contains(
                "Edith is registered with every agent client found on this Mac."))
        #expect(throws: HostCLIError.self) { try cli.execute(["install"]) }
        #expect(throws: HostCLIError.self) { try cli.execute(["install", "--client", "emacs"]) }
        #expect(throws: HostCLIError.self) { try cli.execute(["serve"]) }
        #expect(throws: HostCLIError.self) {
            try cli.execute(["install", "--client", "claude", "--command", "relative/ed"])
        }
    }

    @Test func setupCaptures() throws {
        guard let directory = ProcessInfo.processInfo.environment["EDITH_TEST_CAPTURE_SURFACES"]
        else { return }
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try makeDirectory(home, ".cursor")
        try makeDirectory(home, ".codex")
        try makeDirectory(home, "Library/Application Support/Code/User")
        let command = "/Applications/Edith.app/Contents/MacOS/ed"
        let claudeConfig = home.appendingPathComponent(".claude.json")
        let tools = ToolRecorder(available: ["claude"]) { arguments in
            guard arguments.starts(with: ["mcp", "add"]) else { return }
            let entry = "{\"mcpServers\":{\"edith\":{\"type\":\"stdio\",\"command\":\"\(command)\",\"args\":[\"mcp\"],\"env\":{}}}}"
            try? Data(entry.utf8).write(to: claudeConfig)
        }
        let cli = HostMCPSetupCLI(
            home: home, executable: URL(fileURLWithPath: command),
            codexHome: nil, tools: tools.runner)
        var transcript = ""
        for arguments in [
            ["status"], ["install", "--client", "all", "--dry-run"], ["install", "--client", "all"],
            ["status"], ["install", "--client", "all"],
        ] {
            let reply = try cli.execute(arguments)
            transcript += "$ ed mcp \(arguments.joined(separator: " "))\n\(reply.stdout)\(reply.stderr)\n"
        }
        let folder = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(transcript.replacingOccurrences(of: home.path, with: "~").utf8)
            .write(to: folder.appendingPathComponent("ed-mcp-install.txt"))
        #expect(transcript.contains("Nothing to change. Ask the agent to call edith_catalog"))
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
        let discover = try #require(instructions.range(of: "1. Discover. Call edith_catalog first."))
        let call = try #require(instructions.range(of: "2. Call. Use the matching edith_* tool."))
        let install = try #require(instructions.range(of: "edith_extensions_install"))
        #expect(discover.lowerBound < call.lowerBound && call.lowerBound < install.lowerBound)
        #expect(instructions.contains("notifications/tools/list_changed"))
        #expect(!instructions.contains("\u{2014}"))
        await server.shutdown()
    }

    @Test func initializeNegotiatesTheClientsProtocolVersion() async throws {
        for (requested, expected) in [
            ("2025-06-18", "2025-06-18"), ("2025-03-26", "2025-03-26"),
            ("2025-11-25", "2025-11-25"), ("2099-01-01", "2025-11-25"),
        ] {
            let output = AgentOutput()
            let server = AgentFixture().server(output)
            try await server.accept(
                Data(
                    "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"\(requested)\",\"clientInfo\":{\"name\":\"fixture\",\"version\":\"1\"},\"capabilities\":{}}}"
                        .utf8))
            #expect(
                try await output.response(1).object?["result"]?.object?["protocolVersion"]
                    == .string(expected))
            await server.shutdown()
        }
    }

    @Test func requestsBeforeInitializationAreInvalidNotResourceErrors() async throws {
        let output = AgentOutput()
        let server = AgentFixture().server(output)
        try await server.accept(
            Data("{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"tools/list\"}".utf8))
        #expect(
            try await output.response(7).object?["error"]?.object?["code"] == .integer(-32600))
        await server.shutdown()
    }

    @Test func agentSessionOverRealStdioDiscoversInstallsThenCalls() async throws {
        var toServer: [Int32] = [-1, -1], fromServer: [Int32] = [-1, -1]
        #expect(pipe(&toServer) == 0 && pipe(&fromServer) == 0)
        defer { for descriptor in toServer + fromServer { Darwin.close(descriptor) } }
        let serverIO = try HostMCPStdio(input: toServer[0], output: fromServer[1])
        let clientIO = try HostMCPStdio(input: fromServer[0], output: toServer[1])
        let fixture = AgentFixture()
        let server = fixture.server(send: { try await serverIO.send($0) })
        let running = Task { try await server.run(receive: { try await serverIO.receive() }) }
        let watchdog = Task {
            try await Task.sleep(for: .seconds(20))
            clientIO.cancel()
            serverIO.cancel()
        }
        defer { watchdog.cancel() }
        let session = StdioSession(io: clientIO)
        let initialized = try await session.request(
            "initialize",
            #"{"protocolVersion":"2025-06-18","clientInfo":{"name":"synthetic-agent","version":"1"},"capabilities":{}}"#
        )
        #expect(initialized["protocolVersion"] == .string("2025-06-18"))
        try await session.notify("notifications/initialized")
        let names = { (value: [String: HostCLIJSON]) in
            value["tools"]?.array?.compactMap { $0.object?["name"]?.string } ?? []
        }
        #expect(
            names(try await session.request("tools/list"))
                == ["edith_catalog", "edith_extensions_install", "edith_music_play"])
        let catalog = try await session.request(
            "tools/call", #"{"name":"edith_catalog","arguments":{"query":"emoji"}}"#)
        let entry = catalog["structuredContent"]?.object?["extensions"]?.array?.first?.object
        #expect(entry?["id"] == .string("emoji") && entry?["status"] == .string("available"))
        let guide = try await session.request("resources/read", #"{"uri":"edith://extensions/emoji"}"#)
        #expect(
            guide["contents"]?.array?.first?.object?["text"]?.string?.contains(
                "edith_extensions_install") == true)
        let missing = try await session.requestError(
            "resources/read", #"{"uri":"edith://extensions/nothing"}"#)
        #expect(missing["code"] == .integer(-32002))
        let preview = try await session.request(
            "tools/call", #"{"name":"edith_extensions_install","arguments":{"arguments":["emoji"]}}"#)
        #expect(
            preview["content"]?.array?.first?.object?["text"]?.string?.contains(
                "\"requiresConfirmation\":true") == true)
        #expect(await fixture.coreCalls().isEmpty)
        let installed = try await session.request(
            "tools/call",
            #"{"name":"edith_extensions_install","arguments":{"arguments":["emoji"],"confirm":true}}"#
        )
        #expect(installed["isError"] == .bool(false))
        try await session.waitForNotification("notifications/tools/list_changed")
        #expect(
            names(try await session.request("tools/list"))
                == [
                    "edith_catalog", "edith_emoji_pick", "edith_extensions_install",
                    "edith_music_play",
                ])
        let picked = try await session.request(
            "tools/call", #"{"name":"edith_emoji_pick","arguments":{"arguments":["--query","tada"]}}"#)
        #expect(picked["isError"] == .bool(false))
        #expect(
            await fixture.coreCalls() == [
                ["extensions", "install", "--json", "emoji"],
                ["emoji", "pick", "--json", "--query", "tada"],
            ])
        serverIO.cancel()
        _ = try? await running.value
        if let directory = ProcessInfo.processInfo.environment["EDITH_TEST_CAPTURE_SURFACES"] {
            let folder = URL(fileURLWithPath: directory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(await session.transcript().utf8).write(
                to: folder.appendingPathComponent("mcp-agent-session.txt"))
        }
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
        let missing = try await output.response(5).object?["error"]?.object
        #expect(missing?["code"] == .integer(-32002))
        #expect(missing?["data"]?.object?["uri"] == .string("edith://nothing"))
        try await server.accept(
            Data("{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"resources/read\",\"params\":{}}".utf8))
        #expect(
            try await output.response(6).object?["error"]?.object?["code"] == .integer(-32602))
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
        let unknown = try await output.response(6).object?["result"]?.object
        #expect(unknown?["isError"] == .bool(true))
        #expect(
            unknown?["content"]?.array?.first?.object?["text"]?.string?.contains(
                "Call edith_catalog without id") == true)
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
        server(send: { try await output.append($0) })
    }

    func server(send: @escaping HostMCPCLI.Send) -> HostMCPCLI {
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
            }, send: send,
            coreExecute: { arguments, _ in
                await state.record(arguments)
                return try ExtensionCLIReply(stdout: "{}\n", stderr: "", exitCode: 0)
            }, index: { Self.index })
    }
}

private final class ToolRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [[String]] = []
    private let available: Set<String>
    private let status: Int32
    private let output: String
    private let effect: @Sendable ([String]) -> Void

    init(
        available: Set<String>, status: Int32 = 0, output: String = "",
        effect: @escaping @Sendable ([String]) -> Void = { _ in }
    ) {
        self.available = available; self.status = status; self.output = output
        self.effect = effect
    }

    var calls: [[String]] { lock.withLock { recorded } }
    func reset() { lock.withLock { recorded = [] } }

    var runner: HostMCPToolRunner {
        HostMCPToolRunner(
            locate: { [available] name in
                available.contains(name) ? URL(fileURLWithPath: "/synthetic/bin/" + name) : nil
            },
            run: { [self] _, arguments in
                lock.withLock { recorded.append(arguments) }
                effect(arguments)
                return .init(status: status, output: output)
            })
    }
}

private actor StdioSession {
    private let io: HostMCPStdio
    private var nextID: Int64 = 1
    private var received: [HostCLIJSON] = []
    private var log: [String] = []

    init(io: HostMCPStdio) { self.io = io }

    private func write(_ line: String) async throws {
        log.append("-> " + line)
        try await io.send(Data(line.utf8))
    }

    private func readUntil(_ match: (HostCLIJSON) -> Bool) async throws -> HostCLIJSON {
        if let found = received.first(where: match) { return found }
        while true {
            guard let data = try await io.receive() else { throw HostCLIError.rejected("Server closed.") }
            let value = try JSONDecoder().decode(HostCLIJSON.self, from: data)
            let text = String(decoding: data, as: UTF8.self)
            log.append("<- " + (text.count > 600 ? String(text.prefix(600)) + " ..." : text))
            received.append(value)
            if match(value) { return value }
        }
    }

    private func send(_ method: String, _ params: String?) async throws -> HostCLIJSON {
        let id = nextID
        nextID += 1
        try await write(
            "{\"jsonrpc\":\"2.0\",\"id\":\(id),\"method\":\"\(method)\""
                + (params.map { ",\"params\":" + $0 } ?? "") + "}")
        return try await readUntil { $0.object?["id"] == .integer(id) }
    }

    func request(_ method: String, _ params: String? = nil) async throws -> [String: HostCLIJSON] {
        guard let result = try await send(method, params).object?["result"]?.object else {
            throw HostCLIError.rejected("\(method) failed.")
        }
        return result
    }

    func requestError(_ method: String, _ params: String? = nil) async throws -> [String: HostCLIJSON] {
        guard let error = try await send(method, params).object?["error"]?.object else {
            throw HostCLIError.rejected("\(method) unexpectedly succeeded.")
        }
        return error
    }

    func notify(_ method: String) async throws {
        try await write("{\"jsonrpc\":\"2.0\",\"method\":\"\(method)\"}")
    }

    func waitForNotification(_ method: String) async throws {
        _ = try await readUntil { $0.object?["method"] == .string(method) }
    }

    func transcript() -> String { log.joined(separator: "\n") + "\n" }
}
