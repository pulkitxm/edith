import AppKit
import EdithExtensionAccounts
import EdithExtensionSupport
import SwiftUI
import Testing
@testable import EdithExtensionUI
@testable import HerdrUI

@MainActor
@Suite(.serialized)
struct HerdrAgentMenuSnapshotTests {
    init() {
        _ = NSApplication.shared
        HerdrWorkOwnership.enable()
    }

    @Test func paneMenuOpenedInASplitSurvivesLiveUpdatesAndKeepsWorking() async throws {
        let root = try HerdrAccountFixture.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, work) = try await makeStore(root: root)
        let first = agent(pane: "w1:p1", title: "Sample first")
        let second = agent(pane: "w1:p2", title: "Sample second")
        store.hosts = [.local(herdrPresent: true, agents: [first, second])]
        store.open(first)
        store.open(second, beside: .right)
        let actions = HerdrAgentActions()

        let menu = EdithMenu.makeMenu(
            HerdrPaneMenu.items(
                sessionID: first.id, store: store, actions: actions, launchEnabled: false))
        let items = menu.items
        let titles = outline(menu)
        let enabled = enablement(menu)
        let restartMenu = try #require(submenu(menu, "Restart in Account"))
        let restartItems = restartMenu.items

        for step in 0..<60 {
            let status = HerdrAgentStatus.allCases[step % HerdrAgentStatus.allCases.count]
            store.hosts = [
                .local(
                    herdrPresent: true,
                    agents: [
                        agent(pane: "w1:p1", title: "Sample first \(step)", status: status),
                        agent(pane: "w1:p2", title: "Sample second \(step)", status: status),
                    ])
            ]
            store.focus(step.isMultiple(of: 2) ? first.id : second.id)
            store.copiedID = step.isMultiple(of: 3) ? first.id : nil
            await store.claudeAccounts.read()
        }

        #expect(menu.items.elementsEqual(items, by: ===))
        #expect(restartMenu.items.elementsEqual(restartItems, by: ===))
        #expect(outline(menu) == titles)
        #expect(enablement(menu) == enabled)
        for title in [
            "Open", "Open in Herdr Terminal", "Copy Open Command", "Send Message…",
            "Restart Agent…", "Delete Agent…", "Zoom", "Close Pane",
        ] {
            #expect(item(menu, title)?.isEnabled == true, "\(title)")
        }
        #expect(
            restartMenu.items.map(\.title) == [
                "Existing CLI Login", "Sample Work", "Sample Personal",
            ])
        #expect(submenu(menu, "Swap With")?.items.map(\.title) == ["Sample second"])
        #expect(submenu(menu, "Message This Tab")?.items.isEmpty == false)
        #expect(submenu(menu, "Continue in Agent")?.items.isEmpty == false)

        perform(restartMenu, "Sample Work")
        #expect(actions.pendingRestart?.accountID == work.id.uuidString)
        #expect(actions.pendingRestart?.agent.id == first.id)

        perform(menu, "Zoom")
        #expect(store.tab(containing: first.id)?.zoomed == first.id)

        let order = try #require(store.tab(containing: first.id)).layout.panes
        perform(try #require(submenu(menu, "Swap With")), "Sample second")
        #expect(store.tab(containing: first.id)?.layout.panes == order.reversed())
    }

    @Test func paneHeaderContextMenuIsNotRebuiltByLaterRenders() throws {
        let store = HerdrStore(
            defaults: defaults(), agentFocuser: { _, _, _ in }, machinesProvider: { [] })
        let first = agent(pane: "w1:p1", title: "Sample first")
        let second = agent(pane: "w1:p2", title: "Sample second")
        store.hosts = [.local(herdrPresent: true, agents: [first, second])]
        store.open(first)
        store.open(second, beside: .right)
        let host = NSHostingView(rootView: header(store, first.id))
        let window = offscreenWindow(host)
        defer { window.close() }
        let region = try #require(find(EdithContextMenuView.self, in: host))
        let event = try #require(rightClick(window))

        let menu = try #require(region.menu(for: event))
        let items = menu.items
        let titles = outline(menu)
        for step in 0..<40 {
            store.hosts = [
                .local(
                    herdrPresent: true,
                    agents: [
                        agent(pane: "w1:p1", title: "Sample first \(step)", status: .working),
                        agent(pane: "w1:p2", title: "Sample second \(step)", status: .blocked),
                    ])
            ]
            store.focus(step.isMultiple(of: 2) ? second.id : first.id)
            host.rootView = header(store, first.id)
            host.layoutSubtreeIfNeeded()
        }

        #expect(menu.items.elementsEqual(items, by: ===))
        #expect(outline(menu) == titles)
        #expect(item(menu, "Open")?.isEnabled == true)
        #expect(item(menu, "Close Pane")?.isEnabled == true)
        perform(menu, "Zoom")
        #expect(store.tab(containing: first.id)?.zoomed == first.id)
        perform(menu, "Close Pane")
        #expect(store.session(first.id) == nil)
    }

    @Test func agentMenusNeverStartEndOrRepeatSeparators() throws {
        let store = HerdrStore(
            defaults: defaults(), agentFocuser: { _, _, _ in }, machinesProvider: { [] })
        let first = agent(pane: "w1:p1", title: "Sample first")
        let second = agent(pane: "w1:p2", title: "Sample second", kind: "Codex")
        let third = agent(pane: "w2:p1", title: "Sample third", kind: "Shell")
        store.hosts = [.local(herdrPresent: true, agents: [first, second, third])]
        let terminal = HerdrMachineTerminal.agent(for: store.hosts[0])
        store.open(first)
        store.open(second, beside: .right)
        store.open(terminal)
        let actions = HerdrAgentActions()
        let menus: [[EdithMenuItem]] = [
            HerdrPaneMenu.items(
                sessionID: first.id, store: store, actions: actions, launchEnabled: false),
            HerdrPaneMenu.items(
                sessionID: terminal.id, store: store, actions: actions, launchEnabled: false),
            HerdrAgentMenu.items(
                for: [first], store: store, actions: actions, launchEnabled: false),
            HerdrAgentMenu.items(
                for: [third], store: store, actions: actions, launchEnabled: false),
            HerdrAgentMenu.items(
                for: [terminal], store: store, actions: actions, launchEnabled: false),
            HerdrAgentMenu.items(
                for: [first, second], store: store, actions: actions, launchEnabled: false),
            HerdrAgentMenu.items(
                for: [], store: store, actions: actions, launchEnabled: false,
                extra: [.button("Sample extra") {}]),
            HerdrMessageMenu.items(store: store),
        ]

        for items in menus {
            let menu = EdithMenu.makeMenu(items)
            #expect(!menu.items.isEmpty)
            expectClean(menu)
        }
        let terminalMenu = EdithMenu.makeMenu(
            HerdrPaneMenu.items(
                sessionID: terminal.id, store: store, actions: actions, launchEnabled: false))
        #expect(submenu(terminalMenu, "Swap With") == nil)
        #expect(submenu(terminalMenu, "Message This Tab") == nil)
    }

    private func header(_ store: HerdrStore, _ id: String) -> some View {
        let session = store.session(id)!
        let tab = store.tab(containing: id)!
        return HerdrPaneHeader(
            store: store, session: session, tab: tab, focused: tab.focused == id,
            hideAgents: false
        )
        .frame(width: 320, height: 28)
    }

    private func makeStore(root: URL) async throws -> (HerdrStore, ClaudeAccount) {
        let accounts = ClaudeAccountsModel(directory: root.appendingPathComponent("accounts"))
        try await accounts.load()
        let work = ClaudeAccount(name: "Sample Work", credential: "synthetic-work")
        let personal = ClaudeAccount(name: "Sample Personal", credential: "synthetic-personal")
        try await accounts.persist(.init(accounts: [work, personal], defaultID: work.id))
        let store = HerdrStore(
            defaults: defaults(), claudeAccounts: accounts, agentFocuser: { _, _, _ in },
            machinesProvider: { [] })
        return (store, work)
    }

    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "HerdrAgentMenuSnapshotTests-\(UUID().uuidString)")!
    }

    private func agent(
        pane: String, title: String, kind: String = "Claude Code",
        status: HerdrAgentStatus = .idle
    ) -> HerdrAgent {
        HerdrAgent.make(
            machineID: HerdrHostSnapshot.localID, machineName: "Sample Mac", machineIsLocal: true,
            sshTarget: nil, session: "default", pane: pane, kind: kind, status: status,
            title: title, workspace: "Sample project", cwd: "/tmp/sample",
            nativeSession: HerdrNativeSession(provider: "claude", value: "sample-session"))
    }

    private func offscreenWindow(_ host: NSView) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 28), styleMask: [.borderless],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 320, height: 28)
        host.layoutSubtreeIfNeeded()
        return window
    }

    private func rightClick(_ window: NSWindow) -> NSEvent? {
        NSEvent.mouseEvent(
            with: .rightMouseDown, location: NSPoint(x: 40, y: 14), modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0,
            clickCount: 1, pressure: 1)
    }

    private func find<T: NSView>(_ type: T.Type, in root: NSView) -> T? {
        if let match = root as? T { return match }
        for child in root.subviews {
            if let match = find(type, in: child) { return match }
        }
        return nil
    }

    private func item(_ menu: NSMenu, _ title: String) -> NSMenuItem? {
        menu.items.first { $0.title == title }
    }

    private func submenu(_ menu: NSMenu, _ title: String) -> NSMenu? {
        for entry in menu.items {
            if entry.title == title, let submenu = entry.submenu { return submenu }
            if let submenu = entry.submenu, let found = self.submenu(submenu, title) {
                return found
            }
        }
        return nil
    }

    private func perform(_ menu: NSMenu, _ title: String) {
        guard let index = menu.items.firstIndex(where: { $0.title == title }) else {
            Issue.record("Missing \(title)")
            return
        }
        menu.performActionForItem(at: index)
    }

    private func outline(_ menu: NSMenu) -> [String] {
        menu.items.flatMap { entry in
            [entry.isSeparatorItem ? "-" : entry.title]
                + (entry.submenu.map { outline($0).map { "  \($0)" } } ?? [])
        }
    }

    private func enablement(_ menu: NSMenu) -> [Bool] {
        menu.items.flatMap { entry in
            [entry.isEnabled] + (entry.submenu.map(enablement) ?? [])
        }
    }

    private func expectClean(_ menu: NSMenu) {
        let items = menu.items
        #expect(items.first?.isSeparatorItem != true, "\(outline(menu))")
        #expect(items.last?.isSeparatorItem != true, "\(outline(menu))")
        for (left, right) in zip(items, items.dropFirst()) {
            #expect(!(left.isSeparatorItem && right.isSeparatorItem), "\(outline(menu))")
        }
        for entry in items {
            if let submenu = entry.submenu {
                #expect(!submenu.items.isEmpty, "\(entry.title)")
                expectClean(submenu)
            }
        }
    }
}
