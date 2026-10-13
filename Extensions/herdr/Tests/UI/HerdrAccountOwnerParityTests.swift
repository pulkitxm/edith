import AppKit
import EdithExtensionAccounts
import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import SwiftUI
import Testing
@testable import HerdrUI

private actor HerdrAccountParityLaunches {
    var paneCount = 0
    var outputs: [String: [String: String]] = [:]
    var remote: (UUID, UUID, String, [String], String)?

    func pane() -> HerdrCreatedPane {
        paneCount += 1
        return .init(
            workspaceID: "synthetic", tabID: "synthetic-tab", paneID: "synthetic-\(paneCount)")
    }

    func record(_ pane: String, environment: [String: String]) { outputs[pane] = environment }

    func recordRemote(
        _ account: ClaudeAccount, command: String, arguments: [String], pane: String,
        machine: Machine
    ) {
        remote = (account.id, machine.id, command, arguments, pane)
    }
}

@MainActor @Suite(.serialized) struct HerdrAccountOwnerParityTests {
    init() { HerdrWorkOwnership.enable() }

    @Test func defaultAndOverrideLaunchActualSelectedCredentialsBeforeRejectingInvalidPane()
        async throws
    {
        defer { HerdrWorkOwnership.enable() }
        let root = try HerdrAccountFixture.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = HerdrUIDefaults()
        HerdrLaunchSettings.setCommand("/usr/bin/env", for: "Claude Code", in: defaults)
        let model = ClaudeAccountsModel(directory: root.appendingPathComponent("accounts"))
        try await model.load()
        let personal = ClaudeAccount(name: "Personal", credential: "synthetic-personal-token")
        let company = ClaudeAccount(
            name: "Company", authentication: .apiKey, credential: "synthetic-company-key")
        try await model.persist(.init(accounts: [personal, company], defaultID: personal.id))
        let launches = HerdrAccountParityLaunches()
        let store = HerdrStore(
            defaults: defaults, claudeAccounts: model, liveWatcher: { _ in },
            newAgentPaneCreator: { _, _, _, _ in await launches.pane() },
            agentStarter: { _, _, _ in Issue.record("Named account used ambient CLI starter") },
            accountAgentStarter: { launcher, pane in
                let environment = try await HerdrAccountFixture.run(launcher, home: root)
                await launches.record(pane, environment: environment)
            }, machinesProvider: { [] })
        do {
            let host = HerdrHostSnapshot(
                id: "local", name: "Synthetic Mac", isLocal: true,
                herdrPresent: true, reachable: true, agents: [])
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
            #expect(outputs["synthetic-1"]?["CLAUDE_CODE_OAUTH_TOKEN"] == personal.credential)
            #expect(outputs["synthetic-1"]?["ANTHROPIC_API_KEY"] == nil)
            #expect(outputs["synthetic-2"]?["ANTHROPIC_API_KEY"] == company.credential)
            #expect(outputs["synthetic-2"]?["CLAUDE_CODE_OAUTH_TOKEN"] == nil)
            #expect(
                Set(store.accountSessions.values)
                    == Set([personal.id.uuidString, company.id.uuidString]))
            let count = await launches.paneCount
            await #expect(throws: ClaudeAccountError.self) {
                try await store.launchNewAgent(
                    kind: "Claude Code", host: host, existingSpace: nil,
                    newSpaceLabel: "Synthetic", accountID: UUID().uuidString)
            }
            let unavailable = HerdrHostSnapshot(
                id: UUID().uuidString, name: "Synthetic unavailable", isLocal: false,
                herdrPresent: true, reachable: true, agents: [])
            await #expect(throws: HerdrQuinjetError.self) {
                try await store.launchNewAgent(
                    kind: "Claude Code", host: unavailable, existingSpace: nil,
                    newSpaceLabel: "Synthetic", accountID: personal.id.uuidString)
            }
            #expect(await launches.paneCount == count)
        } catch {
            await store.shutdown()
            throw error
        }
        await store.shutdown()
    }

    @Test func namedDefaultReachesOnlySelectedRemoteMachineWithOriginalLaunchOptions()
        async throws
    {
        defer { HerdrWorkOwnership.enable() }
        let root = try HerdrAccountFixture.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = HerdrUIDefaults()
        HerdrLaunchSettings.setCommand("cc", for: "Claude Code", in: defaults)
        HerdrLaunchSettings.setOptions(
            .init(model: "synthetic-model"), for: "Claude Code", in: defaults)
        let selected = Machine(name: "Synthetic selected", host: "selected.invalid")
        let other = Machine(name: "Synthetic other", host: "other.invalid")
        let model = ClaudeAccountsModel(directory: root.appendingPathComponent("accounts"))
        try await model.load()
        let account = ClaudeAccount(name: "Company", credential: "synthetic-remote-token")
        try await model.persist(.init(accounts: [account], defaultID: account.id))
        let launches = HerdrAccountParityLaunches()
        let store = HerdrStore(
            defaults: defaults, claudeAccounts: model, liveWatcher: { _ in },
            newAgentPaneCreator: { _, machine, _, _ in
                #expect(machine?.id == selected.id)
                return await launches.pane()
            },
            agentStarter: { _, _, _ in Issue.record("Named remote account used ambient starter") },
            remoteAccountAgentStarter: { account, command, arguments, pane, machine in
                await launches.recordRemote(
                    account, command: command, arguments: arguments, pane: pane, machine: machine)
            }, machinesProvider: { [selected, other] })
        do {
            let host = HerdrHostSnapshot(
                id: selected.id.uuidString, name: selected.name, isLocal: false,
                herdrPresent: true, reachable: true, agents: [])
            try await store.launchNewAgent(
                kind: "Claude Code", host: host, existingSpace: nil, newSpaceLabel: "Synthetic")
            for _ in 0..<100 {
                if await launches.remote != nil { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let result = await launches.remote
            #expect(result?.0 == account.id)
            #expect(result?.1 == selected.id)
            #expect(result?.2 == "cc")
            #expect(result?.3.contains("synthetic-model") == true)
            #expect(result?.4 == "synthetic-1")
            #expect(store.accountSessions.values.contains(account.id.uuidString))
            let saved = try await ClaudeAccountStorage(directory: model.directory).load()
            #expect(saved.accounts.first?.remoteMachineID == selected.id.uuidString)
        } catch {
            await store.shutdown()
            throw error
        }
        await store.shutdown()
    }

    @Test func accountMachineAndKindFiltersComposeAndClearTogether() {
        let store = HerdrStore(
            defaults: HerdrUIDefaults(), liveWatcher: { _ in }, machinesProvider: { [] })
        let accountID = UUID().uuidString
        func agent(_ pane: String, machine: String, kind: String) -> HerdrAgent {
            .make(
                machineID: machine, machineName: "Synthetic " + machine,
                machineIsLocal: machine == "local",
                sshTarget: nil, session: "fixture", pane: pane, kind: kind, status: .working,
                title: pane, workspace: "Synthetic space", cwd: "/synthetic/fixture")
        }
        let work = agent("work", machine: "local", kind: "Claude Code")
        let cli = agent("cli", machine: "local", kind: "Claude Code")
        let remote = agent("remote", machine: "remote", kind: "Claude Code")
        let gemini = agent("gemini", machine: "local", kind: "Gemini")
        let agents = [work, cli, remote, gemini]
        store.hosts = [
            .init(
                id: "local", name: "Synthetic inventory", isLocal: true, herdrPresent: true,
                reachable: true, agents: agents)
        ]
        store.accountSessions[work.id] = accountID
        store.accountSessions[remote.id] = accountID
        store.accountFilter = accountID
        #expect(store.filteredAgents == [work, remote])
        store.machineFilter = "local"
        #expect(store.filteredAgents == [work])
        store.kindFilter = ["Gemini"]
        #expect(store.filteredAgents.isEmpty)
        store.kindFilter = ["Claude Code"]
        store.accountFilter = "cli"
        #expect(store.filteredAgents == [cli])
        store.accountFilter = accountID
        store.spaceGroupingEnabled = true
        store.clearSessionFilters()
        #expect(store.filteredAgents == agents)
        #expect(store.accountFilter == nil)
        #expect(store.machineFilter == "all")
        #expect(store.kindFilter.isEmpty)
        #expect(!store.spaceGroupingEnabled)
    }

    @Test func shellEditorPreservesTypedHyphensQuotesAndDisabledState() throws {
        var value = ""
        let host = NSHostingView(
            rootView: ShellInputEditor(
                text: Binding(get: { value }, set: { value = $0 }), label: "Launch settings"
            )
            .disabled(false).frame(width: 440, height: 48))
        host.layoutSubtreeIfNeeded()
        func editor(in view: NSView) -> NSTextView? {
            if let text = view as? NSTextView { return text }
            return view.subviews.compactMap { editor(in: $0) }.first
        }
        let text = try #require(editor(in: host))
        #expect(!text.isAutomaticDashSubstitutionEnabled)
        #expect(!text.isAutomaticQuoteSubstitutionEnabled)
        #expect(!text.isAutomaticTextReplacementEnabled)
        let input = "--verbose\nIS_DEMO='1'"
        for character in input {
            text.insertText(
                String(character), replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        #expect(text.string == input)
        #expect(value == input)
        host.rootView = ShellInputEditor(
            text: Binding(get: { value }, set: { value = $0 }), label: "Launch settings"
        )
        .disabled(true).frame(width: 440, height: 48)
        host.layoutSubtreeIfNeeded()
        #expect(!text.isEditable)
    }
}
