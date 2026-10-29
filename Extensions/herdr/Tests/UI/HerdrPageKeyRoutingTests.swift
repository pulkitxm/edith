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
        private let suite = "HerdrPageKeyRoutingTests-\(UUID().uuidString)"

        init() async throws {
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
            window.identifier = NSUserInterfaceItemIdentifier("EdithMainWindow")
            window.contentView = host
            window.makeKeyAndOrderFront(nil)
            for _ in 0..<4 {
                window.layoutIfNeeded()
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(40))
            }
        }

        func press(_ keyCode: UInt16, _ characters: String, _ flags: NSEvent.ModifierFlags) {
            let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)!
            NSApp.sendEvent(event)
        }

        func equivalent(_ keyCode: UInt16, _ characters: String, _ flags: NSEvent.ModifierFlags)
            -> Bool
        {
            let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)!
            return window.performKeyEquivalent(with: event)
        }

        func close() {
            window.orderOut(nil)
            store.closeAll()
            UserDefaults().removePersistentDomain(forName: suite)
        }
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
