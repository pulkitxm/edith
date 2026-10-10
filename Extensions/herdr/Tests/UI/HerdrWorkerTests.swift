import EdithExtensionSupport
import Foundation
import Testing
@testable import HerdrUI

@MainActor @Suite(.serialized) struct HerdrWorkerTests {
    @Test func surfacesFilterSourcesFieldsAndOpaqueCurrentActions() async throws {
        let store = makeStore()
        let first = agent("first", host: "local")
        let second = agent("second", host: UUID().uuidString)
        store.hosts = [host(first), host(second)]
        let worker = HerdrWorker(store: store, automaticActions: false)
        let surface = HerdrSurface(worker: worker, privacyValues: { [:] })
        var tile = SurfaceTile(.ability("herdr"))
        tile.sourceIDs = ["synthetic tool"]
        tile.itemLimit = 1
        tile.hiddenFields = ["waiting", "metadata"]
        let request = SurfaceSnapshotRequest(target: .home, tile: tile)
        let snapshot = try SurfaceSnapshot.decode(
            try await surface.execute(
                "surface.snapshot", payload: request.encoded(providerID: "herdr")),
            providerID: "herdr")
        #expect(snapshot.rows.count == 1 && snapshot.rows.first?.sourceID == "synthetic tool")
        #expect(
            snapshot.sources.contains { $0.id == "synthetic tool" }
                && snapshot.rows.first?.detail == "")
        #expect(!snapshot.metrics.contains { $0.id == "waiting" })
        let action = try #require(snapshot.rows.first?.actions.first?.id)
        #expect(UUID(uuidString: action) != nil && !action.contains(first.id))
        let actionRequest = SurfaceActionRequest(snapshot: request, actionID: action)
        store.hosts = []
        await #expect(throws: ExtensionPeerError.self) {
            try await surface.execute(
                "surface.perform", payload: actionRequest.encoded(providerID: "herdr"))
        }
        #expect(store.tabs.isEmpty)
        await worker.shutdown()
    }

    @Test func privacyHidesSourcesAndPreventsDispatchAndCancellationPreventsOpen() async throws {
        let store = makeStore()
        store.hosts = [host(agent("private", host: "local"))]
        let worker = HerdrWorker(store: store, automaticActions: false)
        let surface = HerdrSurface(worker: worker, privacyValues: { ["active": "1"] })
        let request = SurfaceSnapshotRequest(target: .notch, tile: .init(.ability("herdr")))
        let snapshot = try SurfaceSnapshot.decode(
            try await surface.execute(
                "surface.snapshot", payload: request.encoded(providerID: "herdr")),
            providerID: "herdr")
        #expect(snapshot.rows.isEmpty && snapshot.sources.isEmpty && snapshot.actions.isEmpty)
        await #expect(throws: ExtensionPeerError.self) {
            try await surface.execute(
                "surface.perform",
                payload: SurfaceActionRequest(snapshot: request, actionID: "open").encoded(
                    providerID: "herdr"))
        }
        let cancelled = Task {
            try? await Task.sleep(for: .milliseconds(10))
            return try await worker.execute(
                "herdr.open",
                payload: JSONSerialization.data(withJSONObject: ["agentID": store.agents[0].id]))
        }
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(store.tabs.isEmpty)
        await worker.shutdown()
    }

    @Test func admissionResolvesCurrentAgentsAndRejectsInjectedFieldsPathsAndOversize() async throws
    {
        let store = makeStore()
        let current = agent("current", host: "local")
        store.hosts = [host(current)]
        let worker = HerdrWorker(store: store, automaticActions: false)
        for (command, payload) in [
            ("herdr.open", Data(#"{"agentID":"stale"}"#.utf8)),
            (
                "herdr.open",
                try JSONSerialization.data(withJSONObject: [
                    "agentID": current.id, "command": "rm -rf /tmp/mock",
                ])
            ),
            (
                "herdr.message",
                try JSONSerialization.data(withJSONObject: [
                    "agentID": current.id, "text": String(repeating: "x", count: 16_385),
                ])
            ),
            ("herdr.hooks.list", Data(#"{"path":"/tmp/mock"}"#.utf8)),
            ("herdr.open", Data(repeating: 0, count: 32_769)),
            ("herdr.unknown", Data("{}".utf8)),
        ] {
            await #expect(throws: (any Error).self) {
                try await worker.execute(command, payload: payload)
            }
        }
        #expect(store.tabs.isEmpty)
        await worker.shutdown()
        await #expect(throws: ExtensionPeerError.self) {
            try await worker.execute("herdr.hooks.list", payload: Data("{}".utf8))
        }
    }

    @Test func shutdownCancelsAndAwaitsWorkAndReleasesTerminalAndTopicOwners() async throws {
        let store = makeStore()
        let worker = HerdrWorker(store: store, automaticActions: false)
        var entered = false
        var exited = false
        HerdrWorkOwnership.start {
            entered = true
            do { try await Task.sleep(for: .seconds(60)) } catch {}
            try? await Task.sleep(for: .milliseconds(5))
            exited = true
        }
        while !entered { await Task.yield() }
        let stream = HerdrTopicFeed.values(.sessions)
        let ended = Task {
            var count = 0; for await _ in stream { count += 1 }; return count
        }
        await worker.shutdown()
        await worker.shutdown()
        #expect(exited && HerdrWorkOwnership.pendingCount == 0 && HerdrWorkOwnership.stopped)
        #expect(await ended.value == 0 && store.tabs.isEmpty && MachineRegistry.machines().isEmpty)
        var afterStopRan = false
        await HerdrWorkOwnership.start { afterStopRan = true }.value
        #expect(!afterStopRan)
    }

    @Test func metadataBoundsPreserveUnicodeAndRemoveNulls() {
        let bounded = HerdrWorker.bounded(String(repeating: "😀\u{0}", count: 1000), 512)
        #expect(bounded.utf8.count == 512 && !bounded.contains("\u{0}") && !bounded.contains("�"))
    }

    private func makeStore() -> HerdrStore {
        HerdrStore(
            defaults: UserDefaults(suiteName: "herdr.fixture." + UUID().uuidString)!,
            machinesProvider: { [] })
    }
    private func agent(_ title: String, host: String) -> HerdrAgent {
        .make(
            machineID: host, machineName: "Synthetic host", machineIsLocal: host == "local",
            sshTarget: nil, session: "synthetic", pane: title, kind: "Synthetic tool",
            status: .working, title: title, workspace: "Mock", cwd: "/tmp/mock")
    }
    private func host(_ agent: HerdrAgent) -> HerdrHostSnapshot {
        .init(
            id: agent.machineID, name: agent.machineName, isLocal: agent.machineIsLocal,
            herdrPresent: true, reachable: true, agents: [agent])
    }
}
