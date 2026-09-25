import AppKit
import Foundation
import Testing

@testable import Edith
@testable import EdithKit

private actor HerdrPanelHerdr {
    private(set) var opened: [(session: String, cwd: String?, machine: UUID?)] = []
    private(set) var closed: [String] = []
    private(set) var ran: [(pane: String, command: String)] = []
    private var processes: [String: HerdrPaneState] = [:]
    private var nextPane = 1

    func open(session: String, cwd: String?, machine: Machine?) -> HerdrCreatedPane {
        opened.append((session, cwd, machine?.id))
        let pane = "w9:p\(nextPane)"
        nextPane += 1
        processes[pane] = .live(HerdrPaneProcess(name: "zsh", command: "-zsh", running: false))
        return HerdrCreatedPane(workspaceID: "w9", tabID: "w9:t\(nextPane)", paneID: pane)
    }

    func state(_ pane: String) -> HerdrPaneState {
        processes[pane] ?? .missing
    }

    func close(_ pane: String) {
        closed.append(pane)
        processes[pane] = nil
    }

    func type(_ command: String, in pane: String) {
        ran.append((pane, command))
    }

    var typed: [String] { ran.map(\.command) }

    func run(_ name: String, command: String, in pane: String) {
        processes[pane] = .live(HerdrPaneProcess(name: name, command: command, running: true))
    }

    func exit(_ pane: String) {
        processes[pane] = nil
    }

    var openedSessions: [String] { opened.map(\.session) }
    var openedDirectories: [String?] { opened.map(\.cwd) }
    var openedMachines: [UUID?] { opened.map(\.machine) }

    nonisolated var operations: HerdrPanelTerminalOperations {
        HerdrPanelTerminalOperations(
            open: { session, cwd, machine in
                await self.open(session: session, cwd: cwd, machine: machine)
            },
            state: { _, pane, _ in await self.state(pane) },
            close: { _, pane, _ in await self.close(pane) },
            run: { _, pane, command, _ in await self.type(command, in: pane) })
    }
}

@MainActor
@Suite struct HerdrTerminalPanelTests {
    @Test func controlBacktickOpensATerminalInTheFocusedAgentsDirectory() async throws {
        let herdr = HerdrPanelHerdr()
        let store = makeStore(herdr)
        store.open(agent("Claude Code", pane: "a", cwd: "/repo"))
        let owner = store.selectedTab

        #expect(store.performTerminalPanelKey(keyCode: 50, characters: "`", modifiers: .control))

        #expect(store.terminalPanels.isOpen(owner))
        #expect(store.terminalPanels.holdsFocus(owner))
        let terminal = try #require(store.terminalPanels.terminals(of: owner).first)
        try await eventually { store.terminalPanels.terminals[terminal.id]?.process != nil }
        #expect(await herdr.openedSessions == ["default"])
        #expect(await herdr.openedDirectories == ["/repo"])
        #expect(await herdr.openedMachines == [nil])
        #expect(store.terminalPanels.terminals[terminal.id]?.title == "zsh")
    }

    @Test func controlBacktickFocusesThenHidesAndCommandJTogglesVisibility() async throws {
        let herdr = HerdrPanelHerdr()
        let store = makeStore(herdr)
        store.open(agent("Codex", pane: "a"))
        let owner = store.selectedTab
        store.perform(.toggle)
        store.focus(store.tabs[0].focused)
        #expect(store.terminalPanels.isOpen(owner))
        #expect(!store.terminalPanels.holdsFocus(owner))

        store.perform(.toggle)
        #expect(store.terminalPanels.holdsFocus(owner))
        store.perform(.toggle)
        #expect(!store.terminalPanels.isOpen(owner))

        #expect(store.performTerminalPanelKey(keyCode: 38, characters: "j", modifiers: .command))
        #expect(store.terminalPanels.isOpen(owner))
        #expect(store.terminalPanels.terminals(of: owner).count == 1)
        store.perform(.visibility)
        #expect(!store.terminalPanels.isOpen(owner))
        try await eventually { await herdr.openedSessions.count == 1 }
    }

    @Test func eachTabKeepsItsOwnTerminals() async throws {
        let store = makeStore(HerdrPanelHerdr())
        store.open(agent("Claude Code", pane: "a"))
        let first = store.selectedTab
        store.perform(.toggle)
        store.perform(.new)
        store.open(agent("Codex", pane: "b"))
        let second = store.selectedTab

        #expect(store.terminalPanels.terminals(of: first).count == 2)
        #expect(!store.terminalPanels.isOpen(second))
        store.perform(.toggle)
        #expect(store.terminalPanels.terminals(of: second).count == 1)
        #expect(store.terminalPanels.terminals(of: first).count == 2)
    }

    @Test func terminalsAreNamedAfterTheirProcessAndDropWhenTheShellExits() async throws {
        let herdr = HerdrPanelHerdr()
        let store = makeStore(herdr)
        store.open(agent("Claude Code", pane: "a"))
        let owner = store.selectedTab
        store.perform(.toggle)
        let id = try #require(store.terminalPanels.terminals(of: owner).first?.id)
        try await eventually { store.terminalPanels.terminals[id]?.pane != nil }
        let pane = try #require(store.terminalPanels.terminals[id]?.pane)

        await herdr.run("npm", command: "npm run dev", in: pane)
        await store.terminalPanels.refresh(owner)
        #expect(store.terminalPanels.terminals[id]?.title == "npm")
        #expect(store.terminalPanels.terminals[id]?.running == true)

        await herdr.exit(pane)
        await store.terminalPanels.refresh(owner)
        #expect(store.terminalPanels.terminals[id] == nil)
        #expect(!store.terminalPanels.isOpen(owner))
    }

    @Test func closingATerminalClosesItsHerdrTab() async throws {
        let herdr = HerdrPanelHerdr()
        let store = makeStore(herdr)
        store.open(agent("Claude Code", pane: "a"))
        let owner = store.selectedTab
        store.perform(.toggle)
        store.perform(.new)
        let ids = store.terminalPanels.terminals(of: owner).map(\.id)
        try await eventually {
            ids.allSatisfy { store.terminalPanels.terminals[$0]?.pane != nil }
        }
        let pane = try #require(store.terminalPanels.terminals[ids[1]]?.pane)

        store.terminalPanels.close(ids[1])

        #expect(store.terminalPanels.terminals(of: owner).map(\.id) == [ids[0]])
        #expect(store.terminalPanels.selectedID(in: owner) == ids[0])
        try await eventually { await herdr.closed == [pane] }
    }

    @Test func closingARunningTerminalAsksFirst() async throws {
        let herdr = HerdrPanelHerdr()
        let store = makeStore(herdr)
        store.open(agent("Claude Code", pane: "a"))
        let owner = store.selectedTab
        store.perform(.toggle)
        let id = try #require(store.terminalPanels.terminals(of: owner).first?.id)
        try await eventually { store.terminalPanels.terminals[id]?.pane != nil }
        let pane = try #require(store.terminalPanels.terminals[id]?.pane)
        await herdr.run("npm", command: "npm run dev", in: pane)

        store.terminalPanels.requestClose(id)
        try await eventually { store.terminalPanels.closeRequest != nil }
        let request = try #require(store.terminalPanels.closeRequest)
        #expect(request.scope == .terminal)
        #expect(request.title == "Close this terminal?")
        #expect(request.message == "npm is still running in this terminal. Closing it stops it.")
        #expect(store.terminalPanels.terminals[id] != nil)

        store.terminalPanels.closeRequest = nil
        #expect(store.terminalPanels.terminals[id] != nil)
        #expect(await herdr.closed.isEmpty)

        store.terminalPanels.requestClose(id)
        try await eventually { store.terminalPanels.closeRequest != nil }
        store.terminalPanels.closeRequest?.proceed()

        #expect(store.terminalPanels.terminals[id] == nil)
        try await eventually { await herdr.closed == [pane] }
    }

    @Test func closingAnIdleTerminalDoesNotAsk() async throws {
        let herdr = HerdrPanelHerdr()
        let store = makeStore(herdr)
        store.open(agent("Claude Code", pane: "a"))
        let owner = store.selectedTab
        store.perform(.toggle)
        let id = try #require(store.terminalPanels.terminals(of: owner).first?.id)
        try await eventually { store.terminalPanels.terminals[id]?.process != nil }
        let pane = try #require(store.terminalPanels.terminals[id]?.pane)

        store.terminalPanels.requestClose(id)

        try await eventually { store.terminalPanels.terminals[id] == nil }
        #expect(store.terminalPanels.closeRequest == nil)
        try await eventually { await herdr.closed == [pane] }
    }

    @Test func closingATabWithIdleTerminalsClosesThemWithoutAsking() async throws {
        let herdr = HerdrPanelHerdr()
        let store = makeStore(herdr)
        store.open(agent("Claude Code", pane: "a"))
        let owner = store.selectedTab
        store.perform(.toggle)
        let id = try #require(store.terminalPanels.terminals(of: owner).first?.id)
        try await eventually { store.terminalPanels.terminals[id]?.pane != nil }
        let pane = try #require(store.terminalPanels.terminals[id]?.pane)

        store.closeTab(owner)

        try await eventually { store.tabs.isEmpty }
        #expect(store.terminalPanels.closeRequest == nil)
        #expect(store.terminalPanels.terminals.isEmpty)
        try await eventually { await herdr.closed == [pane] }
    }

    @Test func closingATabWithARunningTerminalAsksFirst() async throws {
        let herdr = HerdrPanelHerdr()
        let store = makeStore(herdr)
        store.open(agent("Claude Code", pane: "a"))
        let owner = store.selectedTab
        store.perform(.toggle)
        let id = try #require(store.terminalPanels.terminals(of: owner).first?.id)
        try await eventually { store.terminalPanels.terminals[id]?.pane != nil }
        let pane = try #require(store.terminalPanels.terminals[id]?.pane)
        await herdr.run("npm", command: "npm run dev", in: pane)

        store.closeTab(owner)
        try await eventually { store.terminalPanels.closeRequest != nil }
        let request = try #require(store.terminalPanels.closeRequest)
        #expect(request.running == ["npm"])
        #expect(request.scope == .tab)
        #expect(store.tabs.map(\.id) == [owner])
        #expect(await herdr.closed.isEmpty)

        store.terminalPanels.closeRequest = nil
        #expect(store.tabs.map(\.id) == [owner])
        #expect(store.terminalPanels.terminals[id] != nil)

        store.closeTab(owner)
        try await eventually { store.terminalPanels.closeRequest != nil }
        store.terminalPanels.closeRequest?.proceed()

        #expect(store.tabs.isEmpty)
        #expect(store.terminalPanels.terminals.isEmpty)
        try await eventually { await herdr.closed == [pane] }
    }

    @Test func mergingATabCarriesItsTerminalsAlong() async throws {
        let store = makeStore(HerdrPanelHerdr())
        store.open(agent("Claude Code", pane: "a"))
        let source = store.selectedTab
        store.perform(.toggle)
        store.open(agent("Codex", pane: "b"))
        let target = store.selectedTab
        let id = try #require(store.terminalPanels.terminals(of: source).first?.id)

        store.merge(source, into: target)
        try await eventually { store.terminalPanels.terminals(of: target).count == 1 }

        #expect(store.terminalPanels.terminals(of: target).first?.id == id)
        #expect(store.terminalPanels.terminals(of: source).isEmpty)
        #expect(store.terminalPanels.isOpen(target))
    }

    @Test func movingTheOnlyAgentOutOfATabParksItsTerminalsOnTheBoard() async throws {
        let herdr = HerdrPanelHerdr()
        let store = makeStore(herdr)
        let claude = agent("Claude Code", pane: "a")
        store.open(claude)
        store.perform(.toggle)
        let id = try #require(store.terminalPanels.terminals(of: store.selectedTab).first?.id)

        store.close(claude.id)
        try await eventually {
            store.terminalPanels.terminals(of: HerdrStore.boardID).first?.id == id
        }
        #expect(await herdr.closed.isEmpty)
    }

    @Test func theBoardOpensLocalTerminalsInTheHomeDirectory() async throws {
        let herdr = HerdrPanelHerdr()
        let store = makeStore(herdr)

        store.perform(.toggle)

        let origin = store.terminalOrigin(for: HerdrStore.boardID)
        #expect(origin.host == .local)
        #expect(origin.cwd == "~")
        try await eventually { await herdr.openedDirectories == ["~"] }
    }

    @Test func remoteAgentsOpenTerminalsOnTheirMachine() {
        let store = makeStore(HerdrPanelHerdr())
        let remote = remoteAgent(pane: "w1:p1", cwd: "/srv/app")
        store.open(remote)

        let origin = store.terminalOrigin(for: store.selectedTab)

        #expect(origin.host.machineID == remote.machineID)
        #expect(origin.host.machineName == "Build Box")
        #expect(!origin.host.isLocal)
        #expect(origin.cwd == "/srv/app")
        #expect(origin.location == "app · Build Box")
    }

    @Test func sideBySideTabsOfferEachAgentsMachineAndFolder() async throws {
        let herdr = HerdrPanelHerdr()
        let store = makeStore(herdr)
        let local = agent("Claude Code", pane: "a", cwd: "/repo/web")
        let remote = remoteAgent(pane: "w1:p1", cwd: "/srv/api")
        store.open(local)
        store.open(remote, beside: .right)
        let owner = store.selectedTab

        let origins = store.terminalOrigins(for: owner)
        #expect(origins.map(\.id) == [local.id, remote.id])
        #expect(origins.map(\.cwd) == ["/repo/web", "/srv/api"])
        #expect(origins.map(\.host.isLocal) == [true, false])

        store.openTerminal(in: owner, from: origins[0])
        try await eventually { await herdr.openedDirectories == ["/repo/web"] }
        let terminal = try #require(store.terminalPanels.terminals(of: owner).first)
        #expect(terminal.host == origins[0].host)
        #expect(terminal.location == "web")
    }

    @Test func theHomeFolderSettingStartsTerminalsAtHome() {
        let defaults = Self.scratchDefaults()
        defaults.set("home", forKey: AppStorageKeys.Herdr.terminalStartFolder)
        let store = HerdrStore(
            defaults: defaults,
            terminalPanels: HerdrTerminalPanels(
                defaults: defaults, operations: HerdrPanelHerdr().operations))
        store.open(agent("Codex", pane: "a", cwd: "/repo"))

        #expect(store.terminalOrigin(for: store.selectedTab).cwd == "~")
    }

    @Test func theStartupCommandRunsInEveryNewTerminal() async throws {
        let herdr = HerdrPanelHerdr()
        let defaults = Self.scratchDefaults()
        defaults.set(
            "  source .venv/bin/activate ", forKey: AppStorageKeys.Herdr.terminalStartupCommand)
        let store = HerdrStore(
            defaults: defaults,
            terminalPanels: HerdrTerminalPanels(defaults: defaults, operations: herdr.operations))
        store.open(agent("Codex", pane: "a", cwd: "/repo"))

        store.perform(.toggle)

        try await eventually { await herdr.typed == ["source .venv/bin/activate"] }
    }

    @Test func closingWithoutConfirmationSkipsTheRunningCheck() async throws {
        let herdr = HerdrPanelHerdr()
        let defaults = Self.scratchDefaults()
        defaults.set(false, forKey: AppStorageKeys.Herdr.terminalConfirmClose)
        let store = HerdrStore(
            defaults: defaults,
            terminalPanels: HerdrTerminalPanels(defaults: defaults, operations: herdr.operations))
        store.open(agent("Codex", pane: "a"))
        let owner = store.selectedTab
        store.perform(.toggle)
        let id = try #require(store.terminalPanels.terminals(of: owner).first?.id)
        try await eventually { store.terminalPanels.terminals[id]?.pane != nil }
        let pane = try #require(store.terminalPanels.terminals[id]?.pane)
        await herdr.run("npm", command: "npm run dev", in: pane)

        store.closeTab(owner)

        #expect(store.tabs.isEmpty)
        #expect(store.terminalPanels.closeRequest == nil)
        try await eventually { await herdr.closed == [pane] }
    }

    @Test func terminalSettingsFallBackToCleanDefaults() {
        let defaults = Self.scratchDefaults()
        #expect(HerdrTerminalSettings.load(defaults) == HerdrTerminalSettings())
        defaults.set("buttons", forKey: AppStorageKeys.Herdr.terminalMouse)
        defaults.set(40.0, forKey: AppStorageKeys.Herdr.terminalFontSize)
        let loaded = HerdrTerminalSettings.load(defaults)
        #expect(loaded.mouse == .buttons)
        #expect(loaded.fontSize == HerdrTerminalSettings.fontSizeRange.upperBound)
    }

    @Test func theFirstTerminalCreatesTheEdithTerminalsSpace() {
        #expect(
            HerdrTerminalSpace.openArguments(session: "default", cwd: "/repo", existing: [])
                == [
                    "--session", "default", "workspace", "create", "--label", "Edith-terminals",
                    "--no-focus", "--cwd", "/repo",
                ])
    }

    @Test func laterTerminalsBecomeTabsInTheEdithTerminalsSpace() {
        let spaces = [
            HerdrWorkspaceSummary(id: "w1", label: "edith", tabCount: 2, paneCount: 2),
            HerdrWorkspaceSummary(id: "w7", label: "Edith-terminals", tabCount: 1, paneCount: 1),
        ]
        #expect(
            HerdrTerminalSpace.openArguments(session: "default", cwd: nil, existing: spaces) == [
                "--session", "default", "tab", "create", "--workspace", "w7", "--no-focus",
            ])
    }

    @Test func panelKeysOnlyClaimTheirChords() {
        #expect(
            HerdrTerminalPanelKey.resolve(keyCode: 50, characters: "`", modifiers: .control)
                == .toggle)
        #expect(
            HerdrTerminalPanelKey.resolve(
                keyCode: 50, characters: "~", modifiers: [.control, .shift]) == .new)
        #expect(
            HerdrTerminalPanelKey.resolve(keyCode: 38, characters: "j", modifiers: .command)
                == .visibility)
        #expect(
            HerdrTerminalPanelKey.resolve(keyCode: 50, characters: "`", modifiers: .option) == nil)
        #expect(
            HerdrTerminalPanelKey.resolve(
                keyCode: 38, characters: "j", modifiers: [.command, .shift]) == nil)
    }

    @Test func panelHeightIsClampedAndRemembered() {
        let defaults = Self.scratchDefaults()
        let panels = HerdrTerminalPanels(
            defaults: defaults, operations: HerdrPanelHerdr().operations)
        panels.height = 340
        #expect(HerdrTerminalPanels(defaults: defaults).height == 340)
        #expect(
            HerdrTerminalPanelSizing.height(20, maximum: 500)
                == HerdrTerminalPanelSizing.heightMinimum)
        #expect(HerdrTerminalPanelSizing.height(900, maximum: 500) == 500)
    }

    private func makeStore(_ herdr: HerdrPanelHerdr) -> HerdrStore {
        let defaults = Self.scratchDefaults()
        return HerdrStore(
            defaults: defaults,
            terminalPanels: HerdrTerminalPanels(defaults: defaults, operations: herdr.operations))
    }

    private func eventually(
        _ condition: @MainActor () async -> Bool, timeout: Duration = .seconds(3)
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("condition was not met in time")
    }

    private static func scratchDefaults() -> UserDefaults {
        let suite = "HerdrTerminalPanelTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func remoteAgent(pane: String, cwd: String) -> HerdrAgent {
        HerdrAgent.make(
            machineID: "4F6C2A10-0000-4000-8000-000000000001", machineName: "Build Box",
            machineIsLocal: false, sshTarget: "build", session: "default", pane: pane,
            kind: "Codex", status: .idle, title: "Codex", workspace: "", cwd: cwd)
    }

    private func agent(_ kind: String, pane: String, cwd: String = "") -> HerdrAgent {
        HerdrAgent.make(
            machineID: "local", machineName: "This Mac", machineIsLocal: true, sshTarget: nil,
            session: "default", pane: pane, kind: kind, status: .idle, title: kind,
            workspace: "", cwd: cwd)
    }
}
