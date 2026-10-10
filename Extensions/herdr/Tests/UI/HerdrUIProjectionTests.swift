import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import SwiftUI
import Testing
@testable import HerdrUI

@MainActor @Suite(.serialized) struct HerdrUIProjectionTests {
    private func agent(_ id: String) -> HerdrAgent {
        .make(
            machineID: "local", machineName: "Synthetic Mac", machineIsLocal: true,
            sshTarget: nil, session: "fixture", pane: id, kind: "Synthetic tool",
            status: .working, title: id, workspace: "Synthetic space", cwd: "/tmp/fixture")
    }

    private func worker() -> HerdrWorker {
        let defaults = HerdrUIDefaults()
        let store = HerdrStore(defaults: defaults, machinesProvider: { [] })
        store.hosts = [
            .init(
                id: "local", name: "Synthetic Mac", isLocal: true,
                herdrPresent: true, reachable: true, agents: [agent("first"), agent("second")])
        ]
        return HerdrWorker(store: store, defaults: defaults, automaticActions: false)
    }

    @Test func originalLayoutsAndPreferencesReachOwningEngineWithoutUILaunchPlans() async throws {
        defer { HerdrWorkOwnership.enable() }
        let worker = worker()
        let client = HerdrUIClient { try await worker.execute($0, payload: $1) }
        let ui = HerdrStore(uiClient: client)
        try await ui.performUI("herdr.ui.read")
        let first = try #require(ui.agents.first)
        let second = try #require(ui.agents.last)
        ui.open(first)
        ui.open(second, beside: .right)
        ui.detailOpen = false
        ui.railWidth = 310
        for _ in 0..<200 {
            if worker.store.currentTab?.agentIDs == [first.id, second.id],
                worker.store.railWidth == 310
            {
                break
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(worker.store.currentTab?.agentIDs == [first.id, second.id])
        #expect(worker.store.railWidth == 310 && !worker.store.detailOpen)
        #expect(
            ui.sessions.allSatisfy {
                $0.holder.terminalLaunch == nil && $0.holder.descriptor == nil
            })
        ui.toggleZoom(second.id)
        for _ in 0..<200 {
            if worker.store.currentTab?.zoomed == second.id { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(worker.store.currentTab?.zoomed == second.id)
        ui.close(first.id)
        for _ in 0..<200 {
            if worker.store.session(first.id) == nil { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(worker.store.session(first.id) == nil && worker.store.session(second.id) != nil)
        await ui.shutdown()
        await worker.shutdown()
    }

    @Test func checkedFacadeRejectsUnknownAgentsMalformedLayoutAndDisabledOwner() async throws {
        defer { HerdrWorkOwnership.enable() }
        let worker = worker()
        let client = HerdrUIClient { try await worker.execute($0, payload: $1) }
        let original = try await client.perform("herdr.ui.read")
        let state = try #require(try client.state(original))
        var layout = state.layout
        let forged = agent("forged")
        layout.tabs = [HerdrTab(agentID: forged.id)]
        layout.views = [forged.id: .agent]
        layout.selected = layout.tabs[0].id
        await #expect(throws: ExtensionPeerError.self) {
            try await client.perform("herdr.ui.layout", payload: JSONEncoder().encode(layout))
        }
        #expect(worker.store.tabs.isEmpty)
        await #expect(throws: ExtensionPeerError.self) {
            try await client.perform("herdr.ui.read", object: ["executable": "/bin/sh"])
        }
        await worker.shutdown()
        await #expect(throws: ExtensionPeerError.self) { try await client.perform("herdr.ui.read") }
        client.stop()
        #expect(throws: CancellationError.self) { try client.state(original) }
    }

    @Test func cancelledProjectionRejectsLateResponseAndOlderSequence() async throws {
        defer { HerdrWorkOwnership.enable() }
        let worker = worker()
        let first = try await worker.execute("herdr.ui.read", payload: Data("{}".utf8))
        let second = try await worker.execute("herdr.ui.read", payload: Data("{}".utf8))
        var pending: CheckedContinuation<Data, Error>?
        let client = HerdrUIClient { _, _ in
            try await withCheckedThrowingContinuation { pending = $0 }
        }
        #expect(try client.state(second) != nil)
        #expect(try client.state(first) == nil)
        let read = Task { try await client.perform("herdr.ui.read") }
        while pending == nil { await Task.yield() }
        client.stop()
        pending?.resume(returning: second)
        await #expect(throws: CancellationError.self) { try await read.value }
        await worker.shutdown()
    }
}
