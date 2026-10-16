import EdithExtensionSupport
import Foundation
import Testing
@testable import TerminalExtension

@Suite(.serialized) @MainActor struct TerminalSurfaceTests {
    @Test func newCreatesExactlyOneSessionBeforeTheHostOwnsWindowDelivery() async throws {
        let engine = TerminalTestFixture.engine()
        defer { engine.stop() }
        let surface = TerminalSurface(
            engine: engine, privacyValues: { [:] }, home: "/synthetic/home")
        let request = SurfaceActionRequest(
            snapshot: .init(target: .home, tile: .init(.ability("terminal"))), actionID: "new")
        _ = try await surface.execute(
            "surface.perform", payload: request.encoded(providerID: "terminal"))
        #expect(try engine.snapshot().sessions.count == 1)
        #expect(try engine.snapshot().sessions.first?.selected == true)
    }

    @Test func sourcesLimitsFieldsAndActionsUseTheCurrentEngineSessions() async throws {
        let engine = TerminalTestFixture.engine()
        defer { engine.stop() }
        _ = try await engine.execute("terminal.open", payload: Data())
        _ = try await engine.execute("terminal.open", payload: Data())
        let sessions = try engine.snapshot().sessions
        let first = try #require(sessions.first)
        let second = try #require(sessions.last)
        _ = try await engine.execute(
            "terminal.presentation",
            payload: JSONEncoder().encode(
                TerminalEngine.PresentationRequest(
                    session: .init(id: first.id, generation: first.generation),
                    title: "Fixture shell", directory: "/tmp/mock/folder")))
        let surface = TerminalSurface(
            engine: engine, privacyValues: { [:] }, home: "/tmp/mock")
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
        let allowed = SurfaceActionRequest(
            snapshot: request, actionID: "focus/" + first.id.uuidString)
        _ = try await surface.execute(
            "surface.perform", payload: allowed.encoded(providerID: "terminal"))
        #expect(
            try engine.snapshot().sessions.first(where: { $0.id == first.id })?.selected == true)
        _ = try await engine.execute(
            "terminal.close",
            payload: JSONEncoder().encode(
                TerminalEngine.SessionRequest(id: first.id, generation: first.generation)))
        await #expect(throws: ExtensionPeerError.self) {
            try await surface.execute(
                "surface.perform", payload: allowed.encoded(providerID: "terminal"))
        }
    }

    @Test func presenterHidesSessionsAndPreventsCreatingOrFocusingShells() async throws {
        let engine = TerminalTestFixture.engine()
        defer { engine.stop() }
        _ = try await engine.execute("terminal.open", payload: Data())
        let surface = TerminalSurface(
            engine: engine, privacyValues: { ["active": "1"] })
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
        #expect(try engine.snapshot().sessions.count == 1)
    }

    @Test func titlesStayBoundedWithoutNullsOrPartialUnicode() {
        let value = TerminalWorker.bounded(String(repeating: "😀\u{0}", count: 1000), bytes: 512)
        #expect(value.utf8.count == 512 && !value.contains("\u{0}") && !value.contains("�"))
        #expect(SurfaceWidget.ability("terminal").supportsSourceFilters)
    }
}
