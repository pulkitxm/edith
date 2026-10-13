import AppKit
import EdithKit
import Foundation
import SwiftUI
import Testing
@testable import Edith

@MainActor @Suite(.serialized) struct ClaudeAccountsModelTests {
    @Test func launchPickerSelectsTheNamedDefaultWithoutAnExtraEntry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = ClaudeAccountsModel(directory: root)
        let personal = ClaudeAccount(name: "Personal", credential: "synthetic-personal")
        let company = ClaudeAccount(name: "Company", credential: "synthetic-company")
        try await model.persist(.init(accounts: [personal, company], defaultID: company.id))
        #expect(model.launchSelection("default") == company.id.uuidString)
        #expect(model.launchSelection(personal.id.uuidString) == personal.id.uuidString)
        await model.rememberLaunchSelection(personal.id.uuidString)
        let restored = ClaudeAccountsModel(directory: root)
        try await restored.load()
        #expect(restored.launchSelection("default") == personal.id.uuidString)
        var renamed = personal
        renamed.name = "Updated personal"
        try await ClaudeAccountStorage(directory: root).save(.init(accounts: [renamed, company]))
        await model.rememberLaunchSelection(company.id.uuidString)
        try await restored.load()
        #expect(restored.state.accounts.first?.name == "Updated personal")
        #expect(restored.launchSelection("default") == company.id.uuidString)
        try await model.persist(.init(accounts: [personal]))
        #expect(model.launchSelection("default") == personal.id.uuidString)
        try await model.persist(.init())
        #expect(model.launchSelection("default") == "cli")
    }

    @Test func persistenceKeepsNamesCredentialsAndDefaultsInPrivateFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = ClaudeAccountsModel(directory: root)
        let account = ClaudeAccount(name: "Company", credential: "synthetic-token")
        try await model.persist(.init(accounts: [account], defaultID: account.id))
        let restored = ClaudeAccountsModel(directory: root)
        try await restored.load()
        #expect(restored.state == model.state)
        let file = root.appendingPathComponent("accounts.json")
        #expect(
            (try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions]
                as? NSNumber)?.intValue == 0o600)
        #expect(
            (try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions]
                as? NSNumber)?.intValue == 0o700)
        try await model.persist(.init())
        try await restored.load()
        #expect(restored.state.accounts.isEmpty)
        #expect(restored.state.defaultID == nil)
    }

    @Test func launchResolvesDefaultAndOverrideBeforeCreatingThePane() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = scratchDefaults()
        HerdrLaunchSettings.setCommand("/usr/bin/env", for: "Claude Code", in: defaults)
        let launches = AccountLaunchCapture()
        let store = HerdrStore(
            defaults: defaults, liveWatcher: { _ in },
            newAgentPaneCreator: { _, _, _, _ in
                let pane = await launches.nextPane()
                return HerdrCreatedPane(
                    workspaceID: "synthetic", tabID: "synthetic-tab", paneID: pane)
            },
            accountAgentStarter: { account, command, arguments, environment, pane, machine in
                #expect(machine == nil)
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/sh")
                process.arguments = [
                    "-c",
                    try account.launchCommand(
                        command: command, arguments: arguments, environment: environment),
                ]
                process.environment = [
                    "PATH": "/usr/bin:/bin", "SHELL": "/bin/sh", "HOME": root.path,
                    "ANTHROPIC_API_KEY": "wrong",
                ]
                let output = Pipe()
                process.standardOutput = output
                try process.run()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else {
                    throw ClaudeAccountError.invalidRequest
                }
                await launches.record(pane, String(decoding: data, as: UTF8.self))
            }, machinesProvider: { [] })
        store.claudeAccounts = ClaudeAccountsModel(directory: root)
        let personal = ClaudeAccount(name: "Personal", credential: "synthetic-personal-token")
        let company = ClaudeAccount(
            name: "Company", authentication: .apiKey, credential: "synthetic-company-key")
        try await store.claudeAccounts.persist(
            .init(accounts: [personal, company], defaultID: personal.id))
        let host = HerdrHostSnapshot(
            id: "local", name: "Synthetic Mac", isLocal: true,
            herdrPresent: true, reachable: true, agents: [])
        store.hosts = [host]
        try await store.launchNewAgent(
            kind: "Claude Code", host: host, existingSpace: nil, newSpaceLabel: "Synthetic")
        try await store.launchNewAgent(
            kind: "Claude Code", host: host, existingSpace: nil,
            newSpaceLabel: "Synthetic", accountID: company.id.uuidString)
        for _ in 0..<100 {
            if await launches.outputs.count == 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let outputs = await launches.outputs
        #expect(outputs.count == 2)
        #expect(
            outputs["synthetic-1"]?.contains("CLAUDE_CODE_OAUTH_TOKEN=synthetic-personal-token")
                == true)
        #expect(outputs["synthetic-2"]?.contains("ANTHROPIC_API_KEY=synthetic-company-key") == true)
        #expect(
            Set(store.accountSessions.values)
                == Set([personal.id.uuidString, company.id.uuidString]))
        let before = await launches.paneCount
        await #expect(throws: (any Error).self) {
            try await store.launchNewAgent(
                kind: "Claude Code", host: host, existingSpace: nil,
                newSpaceLabel: "Synthetic", accountID: UUID().uuidString)
        }
        let remote = HerdrHostSnapshot(
            id: "remote", name: "Synthetic Remote", isLocal: false,
            herdrPresent: true, reachable: true, agents: [])
        await #expect(throws: (any Error).self) {
            try await store.launchNewAgent(
                kind: "Claude Code", host: remote, existingSpace: nil,
                newSpaceLabel: "Synthetic", accountID: personal.id.uuidString)
        }
        #expect(await launches.paneCount == before)
    }

    @Test func namedAccountsReachTheSelectedRemoteMachineWithLaunchOptions() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = scratchDefaults()
        HerdrLaunchSettings.setCommand("cc", for: "Claude Code", in: defaults)
        HerdrLaunchSettings.setOptions(
            .init(model: "synthetic-model"), for: "Claude Code", in: defaults)
        try HerdrLaunchSettings.setSharedClaudeLaunch(
            arguments: "--verbose", environment: "IS_DEMO=1", in: defaults)
        let machine = Machine(name: "Synthetic Remote", host: "synthetic.invalid")
        let capture = AccountLaunchCapture()
        let store = HerdrStore(
            defaults: defaults, liveWatcher: { _ in },
            newAgentPaneCreator: { _, selected, _, _ in
                #expect(selected?.id == machine.id)
                return HerdrCreatedPane(
                    workspaceID: "synthetic", tabID: "synthetic", paneID: "remote-pane")
            },
            accountAgentStarter: { account, command, arguments, environment, pane, selected in
                #expect(selected?.id == machine.id)
                #expect(command == "cc")
                #expect(arguments.contains("synthetic-model"))
                #expect(arguments.contains("--verbose"))
                #expect(environment == "IS_DEMO=1")
                await capture.record(pane, account.credential)
            }, machinesProvider: { [machine] })
        store.claudeAccounts = ClaudeAccountsModel(directory: root)
        let account = ClaudeAccount(name: "Company", credential: "synthetic-remote-token")
        try await store.claudeAccounts.persist(.init(accounts: [account], defaultID: account.id))
        let host = HerdrHostSnapshot(
            id: machine.id.uuidString, name: machine.name, isLocal: false,
            herdrPresent: true, reachable: true, agents: [])
        try await store.launchNewAgent(
            kind: "Claude Code", host: host, existingSpace: nil, newSpaceLabel: "Synthetic")
        for _ in 0..<100 {
            if await capture.outputs.count == 1 { break }
            await Task.yield()
        }
        #expect(await capture.outputs.count == 1)
        #expect(store.accountSessions.values.contains(account.id.uuidString))
    }

    @Test func reusedPaneStopsBelongingToThePreviousAccount() throws {
        let defaults = scratchDefaults()
        let store = HerdrStore(defaults: defaults, liveWatcher: { _ in }, machinesProvider: { [] })
        var agent = HerdrAgent.make(
            machineID: "local", machineName: "Synthetic Mac", machineIsLocal: true,
            sshTarget: nil, session: "fixture", pane: "same-pane", kind: "Claude Code",
            status: .working,
            title: "Synthetic", workspace: "Synthetic", cwd: "/tmp/fixture")
        agent.nativeSession = .init(provider: "claude", value: "first-session")
        let accountID = UUID().uuidString
        store.accountSessions[agent.id] = accountID
        func snapshot(_ agent: HerdrAgent) -> HerdrHostSnapshot {
            .init(
                id: "local", name: "Synthetic Mac", isLocal: true,
                herdrPresent: true, reachable: true, agents: [agent])
        }
        store.apply([snapshot(agent)])
        #expect(store.accountSessions[agent.id] == accountID)
        let restored = HerdrStore(
            defaults: defaults, liveWatcher: { _ in }, machinesProvider: { [] })
        agent.nativeSession = .init(provider: "claude", value: "replacement-session")
        restored.apply([snapshot(agent)])
        #expect(restored.accountSessions[agent.id] == nil)
        restored.accountFilter = "cli"
        #expect(restored.filteredAgents == [agent])
    }

    @Test func paneCreationFailureDoesNotCreateAccountLaunchFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = HerdrStore(
            defaults: scratchDefaults(), liveWatcher: { _ in },
            newAgentPaneCreator: { _, _, _, _ in
                throw ClaudeAccountError.rejected("Synthetic pane creation failure")
            },
            machinesProvider: { [] })
        store.claudeAccounts = ClaudeAccountsModel(directory: root)
        let account = ClaudeAccount(name: "Synthetic", credential: "synthetic-token")
        try await store.claudeAccounts.persist(.init(accounts: [account], defaultID: account.id))
        let host = HerdrHostSnapshot(
            id: "local", name: "Synthetic Mac", isLocal: true,
            herdrPresent: true, reachable: true, agents: [])
        await #expect(throws: (any Error).self) {
            try await store.launchNewAgent(
                kind: "Claude Code", host: host, existingSpace: nil, newSpaceLabel: "Synthetic")
        }
        let folder = root.appendingPathComponent(account.id.uuidString)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        #expect(store.accountSessions.isEmpty)
    }

    @Test func accountFiltersComposeWithMachineAndKindFiltersAndClearTogether() {
        let store = HerdrStore(defaults: scratchDefaults(), machinesProvider: { [] })
        let accountID = UUID().uuidString
        let agents = ["work", "personal"].map {
            HerdrAgent.make(
                machineID: "local", machineName: "Synthetic Mac", machineIsLocal: true,
                sshTarget: nil, session: "fixture", pane: $0, kind: "Claude Code", status: .working,
                title: $0, workspace: "Synthetic space", cwd: "/tmp/fixture")
        }
        store.hosts = [
            .init(
                id: "local", name: "Synthetic Mac", isLocal: true,
                herdrPresent: true, reachable: true, agents: agents)
        ]
        store.accountSessions[agents[0].id] = accountID
        store.accountFilter = accountID
        #expect(store.filteredAgents == [agents[0]])
        store.accountFilter = "cli"
        #expect(store.filteredAgents == [agents[1]])
        store.accountFilter = accountID
        store.kindFilter = ["Gemini"]
        #expect(store.filteredAgents.isEmpty)
        store.clearSessionFilters()
        #expect(store.filteredAgents == agents)
    }

    @Test func newAgentMenuRendersTheSelectedAccountWithSyntheticWorkspaces() async throws {
        guard let output = ProcessInfo.processInfo.environment["EDITH_ACCOUNT_EVIDENCE_DIR"] else {
            return
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = HerdrStore(
            defaults: scratchDefaults(), liveWatcher: { _ in }, machinesProvider: { [] })
        store.claudeAccounts = ClaudeAccountsModel(directory: root)
        let account = ClaudeAccount(name: "Company", credential: "synthetic-token")
        try await store.claudeAccounts.persist(.init(accounts: [account], defaultID: account.id))
        let host = HerdrHostSnapshot(
            id: "local", name: "Synthetic Mac", isLocal: true,
            herdrPresent: true, reachable: true, agents: [])
        store.hosts = [host]
        let workspaces = [
            HerdrWorkspaceSummary(
                id: "synthetic", label: "Demo workspace", tabCount: 1, paneCount: 1)
        ]
        let model = HerdrNewAgentPopupModel()
        model.selectedKind = "Claude Code"
        model.selectedHost = host
        model.selectedAccountID = account.id.uuidString
        model.workspaces = workspaces
        model.step = .space
        let view = HerdrNewAgentPopup(store: store, model: model)
            .background(Color.white).environment(\.colorScheme, .light)
        let hostView = NSHostingView(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 380),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hostView
        window.appearance = NSAppearance(named: .aqua)
        window.orderFront(nil)
        for _ in 0..<8 {
            try await Task.sleep(for: .milliseconds(40))
            hostView.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            hostView.displayIfNeeded()
        }
        let bitmap = try #require(hostView.bitmapImageRepForCachingDisplay(in: hostView.bounds))
        hostView.cacheDisplay(in: hostView.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
        try data.write(to: URL(fileURLWithPath: output).appendingPathComponent("new-agent.png"))
        window.orderOut(nil)
    }

    @Test func accountEditorRendersFullSyntheticCredentialAtBothWidthsAndSchemes() async throws {
        guard let output = ProcessInfo.processInfo.environment["EDITH_ACCOUNT_EVIDENCE_DIR"] else {
            return
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = ClaudeAccountsModel(directory: root)
        let account = ClaudeAccount(
            name: "Company", credential: "synthetic-oauth-token-visible-in-full")
        try await model.persist(
            .init(
                accounts: [
                    account,
                    ClaudeAccount(name: "Personal", authentication: .browserLogin),
                ], defaultID: account.id))
        try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
        let launchDefaults = scratchDefaults()
        try HerdrLaunchSettings.setSharedClaudeLaunch(
            arguments: "--verbose", environment: "IS_DEMO=1", in: launchDefaults)
        let previousScale = UIScale.current
        defer { UIScale.apply(previousScale) }
        for (name, width, scheme, zoom) in [
            ("compact-light", 440.0, ColorScheme.light, 1.0), ("regular-dark", 580.0, .dark, 1.0),
            ("zoom-light", 660.0, .light, 1.5),
        ] {
            UIScale.apply(zoom)
            let view = VStack(alignment: .leading, spacing: UIScale.pt(18)) {
                ClaudeAccountSettings(accounts: model)
                Divider()
                ClaudeSharedLaunchSettings(defaults: launchDefaults)
            }
            .padding(18).frame(width: width, height: 760 * zoom, alignment: .topLeading)
            .background(scheme == .dark ? Color.black : Color.white)
            .environment(\.colorScheme, scheme)
            let host = NSHostingView(rootView: view)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: width, height: 760 * zoom),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            window.orderFront(nil)
            for _ in 0..<8 {
                try await Task.sleep(for: .milliseconds(40))
                host.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                host.displayIfNeeded()
            }
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: output).appendingPathComponent(name + ".png"))
            window.orderOut(nil)
        }
    }
    private func scratchDefaults() -> UserDefaults {
        UserDefaults(suiteName: "test.session-accounts." + UUID().uuidString)!
    }

}

private actor AccountLaunchCapture {
    var paneCount = 0
    var outputs: [String: String] = [:]
    func nextPane() -> String { paneCount += 1; return "synthetic-\(paneCount)" }
    func record(_ pane: String, _ output: String) { outputs[pane] = output }
}
