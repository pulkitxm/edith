@testable import HerdrUI
import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import Observation
import Testing
import os

@MainActor
@Suite struct HerdrUIAdoptionTests {
    @Test func repeatingTheSameLayoutKeepsOpenTerminalsObservedStateQuiet() {
        let store = HerdrStore()
        let agents = (1...4).map { index in
            HerdrAgent.make(
                machineID: "local", machineName: "This Mac", machineIsLocal: true,
                sshTarget: nil, session: "default", pane: "w\(index):p1", kind: "Claude Code",
                status: .idle, title: "agent-\(index)", workspace: "demo", cwd: "/tmp/demo")
        }
        store.hosts = [
            HerdrHostSnapshot(
                id: "local", name: "This Mac", isLocal: true, herdrPresent: true,
                reachable: true, agents: agents)
        ]
        let tabs = agents.map { HerdrTab(agentID: $0.id) }
        let layout = HerdrUILayoutState(
            tabs: tabs, selected: tabs[1].id, views: [:], arrangements: [])
        store.applyUILayout(layout)
        let holders = store.sessions.map { ObjectIdentifier($0.holder) }

        let invalidated = OSAllocatedUnfairLock(initialState: 0)
        withObservationTracking {
            _ = store.sessions
            _ = store.tabs
            _ = store.selectedTab
            _ = store.savedArrangements
        } onChange: {
            invalidated.withLock { $0 += 1 }
        }
        for _ in 0..<5 { store.applyUILayout(layout) }

        #expect(invalidated.withLock { $0 } == 0)
        #expect(store.sessions.map { ObjectIdentifier($0.holder) } == holders)

        var closed = layout
        closed.tabs.removeLast()
        store.applyUILayout(closed)
        #expect(invalidated.withLock { $0 } == 1)
        #expect(store.sessions.map { ObjectIdentifier($0.holder) } == Array(holders.dropLast()))
    }

    @Test func pollingAnUnchangedUIStateDoesNotInvalidateThePage() async throws {
        defer { HerdrWorkOwnership.enable() }
        let defaults = HerdrUIDefaults()
        let worker = HerdrWorker(
            store: HerdrStore(defaults: defaults, machinesProvider: { [] }),
            defaults: defaults, automaticActions: false)
        let facade = HerdrUIClient { try await worker.execute($0, payload: $1) }
        let store = HerdrStore(uiClient: facade)
        defer { store.stopRendering() }
        let state = try #require(try facade.state(await facade.perform("herdr.ui.read")))
        store.adoptUI(state)

        let invalidated = OSAllocatedUnfairLock(initialState: 0)
        withObservationTracking {
            _ = store.hosts
            _ = store.sessions
            _ = store.tabs
            _ = store.selectedTab
            _ = store.terminalSettings
            _ = store.railOpen
            _ = store.detailOpen
            _ = store.railWidth
            _ = store.inventoryReady
            _ = store.agentStartupMessages
            _ = store.uiPresentations
            _ = store.terminalPanels.terminals
            _ = store.terminalPanels.panels
        } onChange: {
            invalidated.withLock { $0 += 1 }
        }
        let next = try #require(try facade.state(await facade.perform("herdr.ui.read")))
        for _ in 0..<5 { store.adoptUI(next) }

        #expect(invalidated.withLock { $0 } == 0)
    }
}
