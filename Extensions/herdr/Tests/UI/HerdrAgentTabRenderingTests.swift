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
        let agents = (0..<12).map { index in
            HerdrAgent.make(
                machineID: "local", machineName: "This Mac", machineIsLocal: true,
                sshTarget: nil, session: "demo", pane: "w1:p\(index + 1)",
                kind: "Synthetic agent", status: .idle, title: "Task \(index + 1)",
                workspace: "demo", cwd: "/private/tmp")
        }
        page.store.apply([.local(herdrPresent: true, agents: agents)])
        let requests = OwnedEngineRequests { operation, payload in
            let request = try JSONDecoder().decode(OwnedTerminalRequest.self, from: payload)
            let session = try #require(sessions.first { $0.descriptor.handle == request.session })
            return try await session.execute(operation, payload: payload)
        }
        defer { requests.stop() }
        var holders: [TerminalSessionHolder] = []
        var tabs: [String] = []
        var reads = [Int](repeating: 0, count: agents.count)
        for (index, agent) in agents.enumerated() {
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
                    return try await requests.perform($0, payload: $1)
                })
            holders.append(holder)
            await page.settle()
        }
        let views = try holders.map { try #require($0.ghosttyView) }
        #expect(page.store.tabs.count == 12)
        for (step, index) in [0, 11, 5, 0, 5, 11].enumerated() {
            let background = " background-\(step)"
            let session = sessions[index]
            _ = try await session.execute(
                "herdr.terminal.input",
                payload: JSONEncoder().encode(
                    OwnedTerminalRequest(
                        session: session.descriptor.handle, bytes: Data(background.utf8))))
            page.store.selectedTab = tabs[index]
            await page.settle()
            for (candidate, view) in views.enumerated() {
                #expect(holders[candidate].ghosttyView === view)
                #expect(!view.isHidden)
                #expect(view.acceptsFirstResponder == (candidate == index))
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
            #expect(text.components(separatedBy: background).count == 2)
        }
    }
}
