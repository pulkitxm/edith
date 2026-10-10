import EdithExtensionSupport
import Foundation
import Testing

@testable import EdithHostCore

@MainActor @Suite struct HostCommandCLITests {
    @Test func originalAppDocumentationAndContributorLinksKeepTheirStableNames() {
        let entries = HostAppLinksCLI.entries(
            extensions: [
                .init(id: "calendar", title: "Calendar", symbolName: "calendar", category: "Tools")
            ],
            contributors: ["synthetic": URL(string: "https://github.com/synthetic")!])
        let calendar = entries.first { $0.id == "extension-doc:calendar:guide" }
        #expect(calendar?.label == "Calendar: Calendar guide")
        #expect(
            calendar?.url.absoluteString
                == "https://github.com/pulkitxm/edith/blob/main/docs/cli/calendar/README.md")
        #expect(entries.last?.id == "contributor:synthetic")
        #expect(entries.first?.label == "pulkitxm/edith")
        #expect(entries.count == 4)
    }
    @Test func localGuideVersionSchemaAndCompletionRemainAvailableWithoutRunningApp() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cli-\(UUID().uuidString)")
        let cli = HostCommandCLI(
            version: "1.2.3",
            tooling: HostToolingCLI(
                home: root, executable: root.appendingPathComponent("ed"),
                directory: root.appendingPathComponent("bin"), path: []),
            invoke: { _ in throw HostCLIError.unavailable })
        #expect(await cli.run(["version"]).stdout == "1.2.3\n")
        #expect(await cli.run(["guide"]).exitCode == 0)
        #expect(await cli.run(["guide", "agent"]).exitCode == 0)
        #expect(await cli.run(["guide", "agent", "--json"]).exitCode == 2)
        let schema = await cli.run(["schema"])
        let value = try JSONDecoder().decode(HostCLIJSON.self, from: Data(schema.stdout.utf8))
        #expect(value.object?["additionalProperties"] == .bool(false))
        #expect(
            value.object?["properties"]?.object?["appearance"]?.object?["enum"]
                == .strings(["system", "light", "dark"]))
        #expect(
            await cli.run(["__complete", "--index", "2", "--", "ed", "config", "g"]).stdout
                == "get\n")
        #expect(await cli.run(["music", "ls"]).exitCode == 4)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test func coreConfigurationDispatchUsesValidatedEnvelopeAndOriginalOutput() async throws {
        let name = "com.pulkit.edith.tests.core-cli-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let configuration = try HostConfigurationCLI(shared: defaults, standard: defaults)
        let service = HostCoreCLIService(
            configuration: configuration,
            action: { _ in throw HostCLIError.usage("Unexpected action") })
        let root = FileManager.default.temporaryDirectory
        let cli = HostCommandCLI(
            version: "fixture",
            tooling: HostToolingCLI(
                home: root, executable: root.appendingPathComponent("ed"), path: []),
            invoke: { request in
                if request.action == .ls { return Data("[]".utf8) }
                return try await service.execute(request)
            })
        let set = await cli.run(["config", "set", "appearance", "dark", "--json"])
        #expect(set.exitCode == 0 && defaults.string(forKey: "appearance") == "dark")
        #expect(await cli.run(["config", "get", "appearance"]).stdout == "dark\n")
        let changed = await cli.run(["config", "--json", "--changed"])
        let rows = try JSONDecoder().decode(HostCLIJSON.self, from: Data(changed.stdout.utf8)).array
        #expect(rows?.count == 1 && rows?.first?.object?["key"] == .string("appearance"))
        let preview = await cli.run(
            ["config", "import", "synthetic.json", "--dry-run", "--json"],
            input: Data("{\"appearance\":\"light\"}".utf8))
        #expect(preview.exitCode == 0 && defaults.string(forKey: "appearance") == "dark")
        service.shutdown()
        #expect(await cli.run(["config", "get", "appearance"]).exitCode != 0)
    }

    @Test func originalAppConfirmationNavigationRevealAndUpdateArgumentsAreChecked() async throws {
        var calls: [(String, [String: HostCLIJSON])] = []
        let app = HostAppCommandCLI(
            available: Set(HostAppCommandCLI.actions),
            perform: { action, payload in
                calls.append((action, payload))
                return .object(["route": .string("settings/general"), "changed": .bool(true)])
            })
        let actions = try JSONDecoder().decode(
            HostCLIJSON.self, from: Data(try await app.execute(["ls", "--json"]).stdout.utf8))
        #expect(actions.array?.count == 7)
        #expect(actions.array?.first?.object?["action"] == .string("clean-keys"))
        #expect(actions.array?.first?.object?["needs"] == .string("menuBar"))
        #expect(try await app.execute(["quit", "--json"]).exitCode == 0 && calls.isEmpty)
        #expect(try await app.execute(["relaunch", "--json"]).exitCode == 0 && calls.isEmpty)
        _ = try await app.execute(["clear-updates", "--yes", "--json"])
        #expect(calls.last?.0 == "clear-updates")
        #expect(
            try await app.execute(["navigate", "settings/general"]).stdout == "settings/general\n")
        #expect(calls.last?.1["route"] == .string("settings/general"))
        _ = try await app.execute(["reveal", "settings", "--tab", "updates", "--json"])
        #expect(
            calls.last?.1["section"] == .string("settings")
                && calls.last?.1["tab"] == .string("updates"))
        _ = try await app.execute(["updates", "--limit", "3", "--json"])
        #expect(calls.last?.1["limit"] == .integer(3))
        _ = try await app.execute(["check-updates", "--no-wait", "--json"])
        #expect(calls.last?.1["noWait"] == .bool(true))
        let count = calls.count
        for arguments in [
            ["navigate", "settings//general"], ["reveal", "--tab", "updates"],
            ["reveal", "settings", "--list"], ["updates", "--limit", "0"],
            ["quit", "--yes", "--yes"],
        ] {
            await #expect(throws: HostCLIError.self) { try await app.execute(arguments) }
        }
        #expect(calls.count == count)
    }
}

@Suite struct HostCLILifecycleTests {
    @Test func relaunchWaitsForOwnedTargetToExitAndNeverLaunchesWhenQuitIsRejected() async throws {
        let fixture = RelaunchFixture()
        let bundle = URL(fileURLWithPath: "/synthetic/Edith.app")
        let reply = try await HostCLIRelaunch.run(
            bundle: bundle, json: true, quit: { fixture.quit() }, running: { fixture.running() },
            launch: { fixture.launch($0) })
        #expect(reply.exitCode == 0)
        #expect(fixture.events() == ["quit", bundle.path])
        let held = RelaunchFixture()
        await #expect(throws: HostCLIError.self) {
            try await HostCLIRelaunch.run(
                bundle: bundle, json: true, timeout: 0.05, quit: {},
                running: { held.running() }, launch: { held.launch($0) })
        }
        #expect(held.events().isEmpty)
        let cancelled = Task {
            try await HostCLIRelaunch.run(
                bundle: bundle, json: true, quit: {}, running: { held.running() },
                launch: { held.launch($0) })
        }
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(held.events().isEmpty)
    }

    @Test func cameraDownloadsOnlyMissingOwnerAndWaitsForDisableLifecycle() async throws {
        let fixture = CameraLifecycleFixture()
        let camera = HostCameraLifecycleCLI(
            invoke: { try await fixture.invoke($0) }, missingPermissions: { ["camera"] })
        let reply = try await camera.execute(["on", "--json"])
        let result = try JSONDecoder().decode(HostCLIJSON.self, from: Data(reply.stdout.utf8))
        #expect(result.object?["enabled"] == .bool(true))
        #expect(result.object?["missingPermissions"] == .strings(["camera"]))
        #expect(await fixture.actions() == [.info, .install, .enable])
        _ = try await camera.execute(["on"])
        #expect(await fixture.actions() == [.info, .install, .enable, .info, .enable])
        #expect(try await camera.execute(["off"]).stdout == "virtual camera off\n")
        #expect(await fixture.actions().last == .disable)
        let rejecting = CameraLifecycleFixture(rejectDisable: true)
        let blocked = HostCameraLifecycleCLI(
            invoke: { try await rejecting.invoke($0) }, missingPermissions: { [] })
        await #expect(throws: HostCLIError.self) { try await blocked.execute(["off"]) }
        await #expect(throws: HostCLIError.self) { try await camera.execute(["on", "--yes"]) }
    }
}

private final class RelaunchFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true
    private var history: [String] = []
    func quit() {
        lock.withLock {
            history.append("quit"); active = false
        }
    }
    func running() -> Bool { lock.withLock { active } }
    func launch(_ url: URL) { lock.withLock { history.append(url.path) } }
    func events() -> [String] { lock.withLock { history } }
}

private actor CameraLifecycleFixture {
    private var installed = false
    private var enabled = false
    private var history: [HostCLIRequest.Action] = []
    private let rejectDisable: Bool
    init(rejectDisable: Bool = false) { self.rejectDisable = rejectDisable }
    func actions() -> [HostCLIRequest.Action] { history }
    func invoke(_ request: HostCLIRequest) throws -> Data {
        #expect(request.id == "virtualCamera")
        history.append(request.action)
        switch request.action {
        case .install: installed = true
        case .enable: enabled = true
        case .disable:
            if rejectDisable { throw HostCLIError.rejected("Owned capture is still stopping.") }
            enabled = false
        case .info: break
        default: throw HostCLIError.usage("Unexpected camera action")
        }
        return try HostCLIJSON.object([
            "id": .string("virtualCamera"), "installed": .bool(installed),
            "compatible": .bool(installed), "enabled": .bool(enabled), "running": .bool(enabled),
            "version": installed ? .string("1.0.0") : .null,
            "disablePending": .bool(false), "removalPending": .bool(false),
        ]).encoded()
    }
}

@Suite struct HostToolingCLITests {
    @Test func actualLinksAndCompletionsAreInstalledAndForeignLinksSurviveRemoval() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "tooling synthetic ' \(UUID().uuidString)")
        let bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("ed")
        try Data("exit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let tooling = HostToolingCLI(
            home: root, executable: executable, directory: bin, path: [bin.path])
        _ = try tooling.execute(["install", "--json"])
        for name in ["ed", "edith"] {
            #expect(
                try FileManager.default.destinationOfSymbolicLink(
                    atPath: bin.appendingPathComponent(name).path) == executable.path)
        }
        _ = try tooling.execute(["completions", "install", "--shell", "zsh", "--json"])
        _ = try tooling.execute(["completions", "install", "--shell", "zsh", "--json"])
        let profile = try String(contentsOf: root.appendingPathComponent(".zshrc"), encoding: .utf8)
        #expect(profile.split(separator: "\n").count == 1)
        let script = try String(contentsOf: tooling.completionFile(.zsh), encoding: .utf8)
        #expect(
            script.contains("__complete --index")
                && script.contains(HostToolingCLI.quote(executable.path)))
        let parse = Process()
        parse.executableURL = URL(fileURLWithPath: "/bin/zsh")
        parse.arguments = ["-n", tooling.completionFile(.zsh).path]
        parse.standardOutput = FileHandle.nullDevice; parse.standardError = FileHandle.nullDevice
        try parse.run(); parse.waitUntilExit()
        #expect(parse.terminationStatus == 0)
        let foreign = bin.appendingPathComponent("edith")
        try FileManager.default.removeItem(at: foreign)
        try FileManager.default.createSymbolicLink(
            atPath: foreign.path, withDestinationPath: "/synthetic/foreign")
        _ = try tooling.execute(["uninstall", "--json"])
        #expect(!FileManager.default.fileExists(atPath: bin.appendingPathComponent("ed").path))
        #expect(
            try FileManager.default.destinationOfSymbolicLink(atPath: foreign.path)
                == "/synthetic/foreign")
    }
}
