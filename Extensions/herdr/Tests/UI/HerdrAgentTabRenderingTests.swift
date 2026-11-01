@testable import HerdrUI
import AppKit
import EdithExtensionSupport
@testable import GhosttyTerminal
import Testing

@MainActor
@Suite(.serialized) struct HerdrAgentTabRenderingTests {
    @Test func switchingTabsRetainsTheirScreensAndFocusesOnlyTheSelectedAgent() async throws {
        let page = try await RenderedHerdrPage()
        defer { page.close() }
        var sessions: [OwnedTerminalSession] = []
        defer { sessions.forEach { $0.stop() } }
        var holders: [TerminalSessionHolder] = []
        var tabs: [String] = []
        var reads = [Int](repeating: 0, count: page.agents.count)
        for (index, agent) in page.agents.enumerated() {
            page.store.open(agent)
            tabs.append(page.store.selectedTab)
            let holder = try #require(page.store.session(agent.id)?.holder)
            let session = try await OwnedTerminalSession(
                launch: .init(
                    executable: "/bin/sh",
                    arguments: ["-c", "stty raw -echo; printf 'agent-\(index)'; exec cat"],
                    environment: ["PATH=/usr/bin:/bin", "TERM=xterm-256color"],
                    currentDirectory: "/private/tmp", allowsLocalFileLinks: true,
                    resetTerminalAfterInterrupt: false))
            sessions.append(session)
            holder.bind(
                try OwnedTerminalClient(descriptor: session.descriptor) {
                    if $0 == "herdr.terminal.read" { reads[index] += 1 }
                    return try await session.execute($0, payload: $1)
                })
            holders.append(holder)
            await page.settle()
        }
        let views = try holders.map { try #require($0.ghosttyView) }
        for index in [0, 2, 1, 0, 1, 2] {
            page.store.selectedTab = tabs[index]
            await page.settle()
            for (candidate, view) in views.enumerated() {
                #expect(holders[candidate].ghosttyView === view)
                #expect(view.isHidden == (candidate != index))
                #expect(view.hasInputFocus == (candidate == index))
            }
            let inactiveReads = reads
            for _ in 0..<3 { await page.settle() }
            for candidate in views.indices where candidate != index {
                #expect(reads[candidate] == inactiveReads[candidate])
            }
            let view = views[index]
            #expect(view.performBindingAction("select_all"))
            let text = try #require(view.selectedText())
            #expect(text.components(separatedBy: "agent-\(index)").count == 2)
        }
    }
}
