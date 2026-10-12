import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import SwiftUI
import Testing
@testable import HerdrUI

@MainActor @Suite(.serialized) struct ClaudeAccountsModelTests {
    @Test func persistenceKeepsNamesCredentialsAndDefaultsInPrivateFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = ClaudeAccountsModel(directory: root)
        let account = ClaudeAccount(name: "Company", credential: "synthetic-token")
        try model.persist(.init(accounts: [account], defaultID: account.id))
        let restored = ClaudeAccountsModel(directory: root)
        try restored.load()
        #expect(restored.state == model.state)
        let file = root.appendingPathComponent("accounts.json")
        #expect(
            (try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions]
                as? NSNumber)?.intValue == 0o600)
        #expect(
            (try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions]
                as? NSNumber)?.intValue == 0o700)
        try model.persist(.init())
        try restored.load()
        #expect(restored.state.accounts.isEmpty)
        #expect(restored.state.defaultID == nil)
    }

    @Test func peerSaveRejectsStaleBaselineWithoutLosingTheSavedAccount() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = HerdrStore(defaults: HerdrUIDefaults(), machinesProvider: { [] })
        store.claudeAccounts = ClaudeAccountsModel(directory: root)
        let worker = HerdrWorker(store: store, automaticActions: false)
        let client = HerdrUIClient { try await worker.execute($0, payload: $1) }
        let first = ClaudeAccountsModel(client: client)
        let second = ClaudeAccountsModel(client: client)
        await first.read()
        await second.read()
        let account = ClaudeAccount(name: "Personal", credential: "synthetic-token")
        await first.save(.init(accounts: [account]))
        #expect(first.error == nil)
        await second.save(.init(accounts: [ClaudeAccount(name: "Stale", credential: "synthetic")]))
        #expect(second.error != nil)
        #expect(store.claudeAccounts.state.accounts == [account])
        await second.read()
        #expect(second.state == first.state)
    }

    @Test func launchResolvesDefaultAndOverrideBeforeCreatingThePane() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = HerdrUIDefaults()
        HerdrLaunchSettings.setCommand("/usr/bin/env", for: "Claude Code", in: defaults)
        let launches = AccountLaunchCapture()
        let store = HerdrStore(
            defaults: defaults, liveWatcher: { _ in },
            newAgentPaneCreator: { _, _, _, _ in
                let pane = await launches.nextPane()
                return HerdrCreatedPane(workspaceID: "synthetic", tabID: "synthetic-tab", paneID: pane)
            },
            accountAgentStarter: { launcher, pane in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/sh")
                process.arguments = [launcher.path]
                process.environment = ["PATH": "/usr/bin:/bin", "ANTHROPIC_API_KEY": "wrong"]
                let output = Pipe()
                process.standardOutput = output
                try process.run()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else {
                    throw ExtensionPeerError.invalidRequest
                }
                await launches.record(pane, String(decoding: data, as: UTF8.self))
            }, machinesProvider: { [] })
        store.claudeAccounts = ClaudeAccountsModel(directory: root)
        let personal = ClaudeAccount(name: "Personal", credential: "synthetic-personal-token")
        let company = ClaudeAccount(
            name: "Company", authentication: .apiKey, credential: "synthetic-company-key")
        try store.claudeAccounts.persist(
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

    @Test func accountFiltersComposeWithMachineAndKindFiltersAndClearTogether() {
        let store = HerdrStore(defaults: HerdrUIDefaults(), machinesProvider: { [] })
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
        store.kindFilter = ["Gemini"]
        #expect(store.filteredAgents.isEmpty)
        store.clearSessionFilters()
        #expect(store.filteredAgents == agents)
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
        try model.persist(
            .init(
                accounts: [
                    account,
                    ClaudeAccount(name: "Personal", authentication: .browserLogin),
                ], defaultID: account.id))
        try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
        for (name, width, scheme) in [
            ("compact-light", 440.0, ColorScheme.light), ("regular-dark", 580.0, .dark),
        ] {
            let view = ClaudeAccountSettings(accounts: model)
                .padding(18).frame(width: width).environment(\.colorScheme, scheme)
            let host = NSHostingView(rootView: view)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: width, height: 430),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            window.orderFront(nil)
            for _ in 0..<8 {
                try await Task.sleep(for: .milliseconds(40))
                host.layoutSubtreeIfNeeded()
            }
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: output).appendingPathComponent(name + ".png"))
            window.orderOut(nil)
        }
    }
}

private actor AccountLaunchCapture {
    var paneCount = 0
    var outputs: [String: String] = [:]
    func nextPane() -> String { paneCount += 1; return "synthetic-\(paneCount)" }
    func record(_ pane: String, _ output: String) { outputs[pane] = output }
}
