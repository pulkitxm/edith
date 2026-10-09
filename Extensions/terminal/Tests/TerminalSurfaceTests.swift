import EdithExtensionSupport
import Foundation
import Testing
@testable import TerminalExtension

@Suite(.serialized) @MainActor struct TerminalSurfaceTests {
    @Test func sourcesLimitsFieldsAndActionsUseTheCurrentSessions() async throws {
        var shows = 0
        let worker = TerminalWorker(showWindow: { shows += 1 }, shutdownEngine: {})
        defer { worker.shutdown() }
        let first = try #require(worker.openTab()); let second = try #require(worker.openTab())
        first.holder.start(
            .init(
                executable: "/bin/cat", arguments: [], environment: [],
                currentDirectory: "/tmp/mock/folder", startupCommand: nil))
        let surface = TerminalSurface(worker: worker, privacyValues: { [:] }, home: "/tmp/mock")
        var tile = SurfaceTile(.ability("terminal")); tile.itemLimit = 1
        tile.sourceIDs = [first.id.uuidString]; tile.hiddenFields = ["running"]
        let request = SurfaceSnapshotRequest(target: .notch, tile: tile)
        let snapshot = try SurfaceSnapshot.decode(
            try await surface.execute(
                "surface.snapshot", payload: request.encoded(providerID: "terminal")),
            providerID: "terminal")
        #expect(snapshot.rows.map(\.id) == [first.id.uuidString] && snapshot.sources.count == 2)
        #expect(
            snapshot.rows.first?.detail == "~/folder" && snapshot.metrics.map(\.id) == ["sessions"])
        let hidden = SurfaceActionRequest(
            snapshot: request, actionID: "focus/" + second.id.uuidString)
        await #expect(throws: ExtensionPeerError.self) {
            try await surface.execute(
                "surface.perform", payload: hidden.encoded(providerID: "terminal"))
        }
        #expect(shows == 2)
        let allowed = SurfaceActionRequest(
            snapshot: request, actionID: "focus/" + first.id.uuidString)
        _ = try await surface.execute(
            "surface.perform", payload: allowed.encoded(providerID: "terminal"))
        #expect(worker.model.selected == first.id && shows == 3)
        worker.model.closeTab(first.id)
        await #expect(throws: ExtensionPeerError.self) {
            try await surface.execute(
                "surface.perform", payload: allowed.encoded(providerID: "terminal"))
        }
    }

    @Test func presenterHidesSessionsAndPreventsCreatingOrFocusingShells() async throws {
        let worker = TerminalWorker(shutdownEngine: {})
        defer { worker.shutdown() }
        _ = worker.openTab()
        let surface = TerminalSurface(worker: worker, privacyValues: { ["active": "1"] })
        let request = SurfaceSnapshotRequest(target: .home, tile: SurfaceTile(.ability("terminal")))
        let snapshot = try SurfaceSnapshot.decode(
            try await surface.execute(
                "surface.snapshot", payload: request.encoded(providerID: "terminal")),
            providerID: "terminal")
        #expect(snapshot.rows.isEmpty && snapshot.sources.isEmpty && snapshot.actions.isEmpty)
        await #expect(throws: ExtensionPeerError.self) {
            try await surface.execute(
                "surface.perform",
                payload: SurfaceActionRequest(snapshot: request, actionID: "new").encoded(
                    providerID: "terminal"))
        }
        #expect(worker.model.tabs.count == 1)
    }

    @Test func workerTitlesStayBoundedWithoutNullsOrPartialUnicode() {
        let value = TerminalWorker.bounded(String(repeating: "😀\u{0}", count: 1000), bytes: 512)
        #expect(value.utf8.count == 512 && !value.contains("\u{0}") && !value.contains("�"))
        #expect(SurfaceWidget.ability("terminal").supportsSourceFilters)
    }
}
