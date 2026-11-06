import GhosttyTerminal
@testable import HerdrUI
import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import SwiftUI
import Testing

@MainActor
@Suite(.serialized) struct HerdrPageKeyRoutingTests {
    @MainActor private final class Page {
        let store: HerdrStore
        let agents: [HerdrAgent]
        let window: NSWindow
        let host: NSHostingView<AnyView>
        private var sessions: [OwnedTerminalSession] = []
        private let suite = "HerdrPageKeyRoutingTests-\(UUID().uuidString)"

        init(identifier: String = "EdithMainWindow") async throws {
            let defaults = try #require(UserDefaults(suiteName: suite))
            store = HerdrStore(defaults: defaults, liveWatcher: { _ in }, machinesProvider: { [] })
            agents = ["Alpha", "Beta", "Gamma"].enumerated().map { index, title in
                HerdrAgent.make(
                    machineID: "local", machineName: "This Mac", machineIsLocal: true,
                    sshTarget: nil, session: "demo", pane: "w1:p\(index + 1)", kind: "Codex",
                    status: .idle, title: title, workspace: "demo", cwd: "/tmp/demo")
            }
            store.apply([.local(herdrPresent: true, agents: agents)])
            for agent in agents { store.open(agent) }
            host = NSHostingView(
                rootView: AnyView(
                    HerdrPage(store: store)
                        .environment(\.terminalLaunchEnabled, false)
                        .transaction { $0.animation = nil }))
            host.frame = CGRect(x: 0, y: 0, width: 1280, height: 820)
            window = TestWindowHost.window(contentRect: host.frame)
            window.identifier = NSUserInterfaceItemIdentifier(identifier)
            window.contentView = host
            window.makeKeyAndOrderFront(nil)
            for _ in 0..<4 {
                window.layoutIfNeeded()
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(40))
            }
        }

        func event(_ keyCode: UInt16, _ characters: String, _ flags: NSEvent.ModifierFlags)
            -> NSEvent
        {
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)!
        }

        func press(_ keyCode: UInt16, _ characters: String, _ flags: NSEvent.ModifierFlags) {
            NSApp.sendEvent(event(keyCode, characters, flags))
        }

        func equivalent(_ keyCode: UInt16, _ characters: String, _ flags: NSEvent.ModifierFlags)
            -> Bool
        {
            window.performKeyEquivalent(with: event(keyCode, characters, flags))
        }

        func settle(_ rounds: Int) async {
            for _ in 0..<rounds {
                window.layoutIfNeeded()
                host.layoutSubtreeIfNeeded()
                try? await Task.sleep(for: .milliseconds(40))
            }
        }

        func focusedTerminal() async throws -> (GhosttyTerminalView, OwnedTerminalSession) {
            store.selectedTab = try #require(store.tab(containing: agents[0].id)).id
            await settle(4)
            let holder = try #require(store.session(agents[0].id)).holder
            let session = try await OwnedTerminalSession(
                launch: .init(
                    executable: "/bin/sh", arguments: ["-c", "stty raw -echo; cat"],
                    environment: ["PATH=/usr/bin:/bin", "TERM=xterm-256color"],
                    currentDirectory: "/private/tmp", allowsLocalFileLinks: true,
                    resetTerminalAfterInterrupt: false))
            sessions.append(session)
            holder.bind(
                try OwnedTerminalClient(descriptor: session.descriptor) { operation, payload in
                    try await session.execute(operation, payload: payload)
                })
            await settle(30)
            store.focus(agents[0].id)
            await settle(10)
            let terminal = try #require(holder.ghosttyView)
            try #require(window.firstResponder === terminal)
            return (terminal, session)
        }

        func typed(into session: OwnedTerminalSession) async throws -> String {
            await settle(10)
            let client = try OwnedTerminalClient(descriptor: session.descriptor) {
                operation, payload in try await session.execute(operation, payload: payload)
            }
            var output = Data()
            for _ in 0..<10 {
                let chunk = try await client.read(after: UInt64(output.count))
                output.append(chunk.bytes)
                if chunk.bytes.isEmpty { break }
            }
            return String(decoding: output, as: UTF8.self)
        }

        func close() {
            window.orderOut(nil)
            store.closeAll()
            sessions.forEach { $0.stop() }
            UserDefaults().removePersistentDomain(forName: suite)
        }
    }

    @Test func commandKFromAFocusedTerminalOpensSearchWithoutReachingTheTerminal() async throws {
        let page = try await Page()
        defer { page.close() }
        let (terminal, session) = try await page.focusedTerminal()
        #expect(terminal.performKeyEquivalent(with: page.event(40, "k", .command)))
        #expect(page.store.searchPresented)
        page.store.searchPresented = false
        #expect(page.equivalent(40, "k", .command))
        #expect(page.store.searchPresented)
        page.store.searchPresented = false
        page.press(40, "k", .command)
        #expect(page.store.searchPresented)
        terminal.keyDown(with: page.event(7, "x", []))
        let typed = try await page.typed(into: session)
        #expect(typed.contains("x"))
        #expect(!typed.contains("k"))
    }

    @Test func commandKFromAFocusedTerminalOpensSearchInTheDetachedPage() async throws {
        let page = try await Page(identifier: "EdithSection.herdr")
        defer { page.close() }
        let (terminal, _) = try await page.focusedTerminal()
        #expect(terminal.performKeyEquivalent(with: page.event(40, "k", .command)))
        #expect(page.store.searchPresented)
    }

    @Test func commandKFromAFocusedTextFieldOpensSearch() async throws {
        let page = try await Page()
        defer { page.close() }
        let field = NSTextField(frame: CGRect(x: 0, y: 0, width: 200, height: 24))
        page.host.addSubview(field)
        try #require(page.window.makeFirstResponder(field))
        #expect(page.equivalent(40, "k", .command))
        #expect(page.store.searchPresented)
        page.store.searchPresented = false
        page.press(40, "k", .command)
        #expect(page.store.searchPresented)
        #expect(field.stringValue.isEmpty)
    }

    @Test func pageShortcutsFromAFocusedTerminalReachThePage() async throws {
        let page = try await Page()
        defer { page.close() }
        let (terminal, _) = try await page.focusedTerminal()
        let before = page.store.selectedTab
        #expect(terminal.performKeyEquivalent(with: page.event(48, "\t", .control)))
        #expect(page.store.selectedTab != before)
        page.store.focus(page.agents[0].id)
        await page.settle(10)
        let details = page.store.detailOpen
        #expect(
            terminal.performKeyEquivalent(with: page.event(11, "b", [.command, .option])))
        #expect(page.store.detailOpen != details)
        #expect(!terminal.performKeyEquivalent(with: page.event(45, "n", .command)))
        #expect(!terminal.performKeyEquivalent(with: page.event(19, "2", .command)))
    }

    @Test func controlTabSwitchesTabsThroughTheInstalledMonitor() async throws {
        let page = try await Page()
        defer { page.close() }
        let before = page.store.selectedTab
        page.press(48, "\t", .control)
        #expect(page.store.selectedTab != before)
    }

    @Test func controlTabReachesHerdrWhenOnlyTheResponderChainSeesTheKey() async throws {
        let page = try await Page()
        defer { page.close() }
        let before = page.store.selectedTab
        #expect(page.equivalent(48, "\t", .control))
        #expect(page.store.selectedTab != before)
        #expect(page.equivalent(48, "\t", [.control, .shift]))
        #expect(page.store.selectedTab == before)
    }

    @Test func optionBacktickCyclesSplitFocusWhenOnlyTheResponderChainSeesTheKey() async throws {
        let page = try await Page()
        defer { page.close() }
        let first = try #require(page.store.tabs.first)
        page.store.open(page.agents[1], in: first.id, beside: .right)
        try await Task.sleep(for: .milliseconds(80))
        let tab = try #require(page.store.currentTab)
        #expect(tab.isSplit)
        let focused = tab.focused
        #expect(page.equivalent(50, "`", .option))
        #expect(page.store.currentTab?.focused != focused)
    }

    @Test func plainTypingIsNotConsumed() async throws {
        let page = try await Page()
        defer { page.close() }
        #expect(!page.equivalent(0, "a", []))
        #expect(!page.equivalent(48, "\t", []))
        #expect(!page.equivalent(50, "`", []))
    }
}
