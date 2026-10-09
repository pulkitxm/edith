import EdithExtensionSupport
import Foundation
import Testing
@testable import ClipboardExtension

@Suite(.serialized) @MainActor struct ClipboardSurfaceTests {
    private func fixture() throws -> (ClipboardService, UserDefaults, String, URL) {
        let suite = "clipboard.surface.mock." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return (
            ClipboardService(archive: .init(root: root), defaults: defaults, changed: {}), defaults,
            suite, root
        )
    }

    private func seed(_ client: ClipboardClient, _ title: String) async throws -> String {
        let capture = ClipboardCapture(
            payload: .init(
                data: Data(title.utf8), types: ["public.text"], ext: "txt", preview: title),
            sourceApp: "Mock Notes", sourceBundleID: "example.mock.notes")
        _ = try await client.capture(capture)
        return capture.id
    }

    @Test func snapshotsAndOpaqueActionsRespectCurrentRowsSourcesAndVisibility() async throws {
        let (service, defaults, suite, root) = try fixture()
        defer {
            defaults.removePersistentDomain(forName: suite);
            try? FileManager.default.removeItem(at: root)
        }
        let client = ClipboardClient(service: service)
        let textID = try await seed(client, "mock note")
        let linkID = try await seed(client, "https://example.com")
        var copied: [String] = []
        let surface = ClipboardSurface(
            client: client, privacyValues: { [:] }, copy: { copied.append($0.entry.id) })
        var tile = SurfaceTile(.ability("clipboard"))
        tile.sourceIDs = ["text"]; tile.itemLimit = 1; tile.showDetails = false
        let request = SurfaceSnapshotRequest(target: .notch, tile: tile)
        let snapshot = try SurfaceSnapshot.decode(
            try await surface.execute(
                "surface.snapshot", payload: request.encoded(providerID: "clipboard")),
            providerID: "clipboard")
        #expect(snapshot.rows.map(\.id) == [textID])
        #expect(snapshot.rows.first?.detail == "")
        #expect(snapshot.rows.first?.actions.count == 3)
        _ = try await surface.execute(
            "surface.perform",
            payload: SurfaceActionRequest(snapshot: request, actionID: "copy/" + textID).encoded(
                providerID: "clipboard"))
        #expect(copied == [textID])
        _ = try await surface.execute(
            "surface.perform",
            payload: SurfaceActionRequest(snapshot: request, actionID: "pin/" + textID).encoded(
                providerID: "clipboard"))
        #expect(
            try await client.snapshot().entries.first(where: { $0.id == textID })?.pinned == true)
        for invalid in ["copy/" + linkID, "delete/" + UUID().uuidString, "filesystem.delete"] {
            await #expect(throws: ExtensionPeerError.self) {
                try await surface.execute(
                    "surface.perform",
                    payload: SurfaceActionRequest(snapshot: request, actionID: invalid).encoded(
                        providerID: "clipboard"))
            }
        }
        tile.showActions = false
        await #expect(throws: ExtensionPeerError.self) {
            try await surface.execute(
                "surface.perform",
                payload: SurfaceActionRequest(
                    snapshot: .init(target: .home, tile: tile), actionID: "delete/" + textID
                ).encoded(providerID: "clipboard"))
        }
        _ = try await surface.execute(
            "surface.perform",
            payload: SurfaceActionRequest(snapshot: request, actionID: "delete/" + textID).encoded(
                providerID: "clipboard"))
        #expect(try await client.snapshot().entries.map(\.id) == [linkID])
        await #expect(throws: ExtensionPeerError.self) {
            try await surface.execute(
                "surface.perform",
                payload: SurfaceActionRequest(snapshot: request, actionID: "copy/" + textID)
                    .encoded(providerID: "clipboard"))
        }
        await service.stop()
    }

    @Test func presentingMasksBeforeReadingAndRejectsActions() async throws {
        var reads = 0
        let hidden = ClipboardSurface(
            client: .init(send: { _, _ in throw CocoaError(.featureUnsupported) }),
            privacyValues: { ["active": "1"] }, copy: { _ in reads += 1 })
        let request = SurfaceSnapshotRequest(
            target: .home, tile: SurfaceTile(.ability("clipboard")))
        let masked = try SurfaceSnapshot.decode(
            try await hidden.execute(
                "surface.snapshot", payload: request.encoded(providerID: "clipboard")),
            providerID: "clipboard")
        #expect(masked.rows.isEmpty && masked.sources.isEmpty && masked.metrics.isEmpty)
        #expect(reads == 0)
        await #expect(throws: ExtensionPeerError.self) {
            try await hidden.execute(
                "surface.perform",
                payload: SurfaceActionRequest(
                    snapshot: request, actionID: "copy/" + UUID().uuidString
                ).encoded(providerID: "clipboard"))
        }
    }

    @Test func privacyBecomingActiveDuringCopyPreventsPasteboardWrites() async throws {
        let (service, defaults, suite, root) = try fixture()
        defer {
            defaults.removePersistentDomain(forName: suite);
            try? FileManager.default.removeItem(at: root)
        }
        let client = ClipboardClient(service: service)
        let id = try await seed(client, "mock private note")
        let privacy = ClipboardSurfaceTestPrivacy()
        let changingClient = ClipboardClient(send: { operation, payload in
            let result = try await service.perform(operation: operation, payload: payload)
            if operation == ClipboardServiceOperation.copy { await privacy.activate() }
            return result
        })
        var copied = false
        let surface = ClipboardSurface(
            client: changingClient, privacyValues: { privacy.values }, copy: { _ in copied = true })
        let request = SurfaceSnapshotRequest(
            target: .home, tile: SurfaceTile(.ability("clipboard")))
        await #expect(throws: ExtensionPeerError.self) {
            try await surface.execute(
                "surface.perform",
                payload: SurfaceActionRequest(snapshot: request, actionID: "copy/" + id).encoded(
                    providerID: "clipboard"))
        }
        #expect(!copied)
        await service.stop()
    }

    @Test func deskFieldsAndStoppedWorkersCannotExposeOrMutateHistory() async throws {
        let (service, defaults, suite, root) = try fixture()
        defer {
            defaults.removePersistentDomain(forName: suite);
            try? FileManager.default.removeItem(at: root)
        }
        let client = ClipboardClient(service: service)
        _ = try await seed(client, "mock note")
        var stopped = false
        let surface = ClipboardSurface(
            client: client, isStopped: { stopped }, privacyValues: { [:] },
            copy: { _ in Issue.record("Hidden row copied") })
        var tile = SurfaceTile(.desk); tile.hiddenFields = ["clipboard"]
        let request = SurfaceSnapshotRequest(target: .home, tile: tile)
        let snapshot = try SurfaceSnapshot.decode(
            try await surface.execute(
                "surface.snapshot", payload: request.encoded(providerID: "clipboard")),
            providerID: "clipboard")
        #expect(snapshot.rows.isEmpty && snapshot.metrics.isEmpty)
        stopped = true
        await #expect(throws: ExtensionPeerError.self) {
            try await surface.execute(
                "surface.snapshot", payload: request.encoded(providerID: "clipboard"))
        }
        await service.stop()
    }
}

@MainActor private final class ClipboardSurfaceTestPrivacy {
    var values: [String: String] = [:]
    func activate() { values = ["active": "1"] }
}
