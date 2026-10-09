import Foundation
import Testing
@testable import EdithExtensionSupport

@Suite @MainActor
struct SurfaceCommandServiceTests {
    @Test func projectionRespectsSourcesLimitsDetailsFieldsAndActions() {
        var tile = SurfaceTile(.ability("homebrew"))
        tile.sourceIDs = ["formula"]
        tile.itemLimit = 1
        tile.showDetails = false
        tile.hiddenFields = ["updates", "progress", "updated", "refresh"]
        let snapshot = SurfaceSnapshot(
            providerID: "homebrew",
            metrics: [.init("packages", "Packages", "3"), .init("updates", "Updates", "2")],
            rows: [
                .init("a", sourceID: "cask", title: "Cask"),
                .init(
                    "b", sourceID: "formula", title: "Formula", detail: "Private details",
                    progress: 0.5, actions: [.init("open:b", "Open", "arrow.up")]),
                .init("c", sourceID: "formula", title: "Another"),
            ], actions: [.init("refresh", "Refresh", "arrow.clockwise", field: "refresh")],
            updatedAt: Date())
        let value = SurfaceCommandService.project(snapshot, tile: tile)
        #expect(value.metrics.map(\.id) == ["packages"])
        #expect(value.rows.map(\.id) == ["b"])
        #expect(value.rows.first?.detail == "")
        #expect(value.rows.first?.progress == nil)
        #expect(value.rows.first?.actions.count == 1)
        #expect(value.actions.isEmpty)
        #expect(value.updatedAt == nil)
        tile.showActions = false
        #expect(
            SurfaceCommandService.project(snapshot, tile: tile).rows.first?.actions.isEmpty == true)
    }

    @Test func actionsAreCheckedAgainstCurrentSelectionAndState() async throws {
        var tile = SurfaceTile(.ability("homebrew"))
        tile.sourceIDs = ["formula"]
        var performed: [String] = []
        let current = SurfaceSnapshot(
            providerID: "homebrew",
            rows: [
                .init(
                    "a", sourceID: "formula", title: "Formula",
                    actions: [.init("open:a", "Open", "arrow.up")]),
                .init(
                    "b", sourceID: "cask", title: "Cask",
                    actions: [.init("open:b", "Open", "arrow.up")]),
            ])
        for id in ["open:b", "arbitrary:path", "disable"] {
            let action = SurfaceActionRequest(
                snapshot: .init(target: .home, tile: tile), actionID: id)
            await #expect(throws: ExtensionPeerError.self) {
                _ = try await SurfaceCommandService.execute(
                    providerID: "homebrew", command: "surface.perform",
                    payload: action.encoded(providerID: "homebrew"),
                    snapshot: { _ in current }, perform: { performed.append($0) })
            }
        }
        #expect(performed.isEmpty)
        let action = SurfaceActionRequest(
            snapshot: .init(target: .notch, tile: tile), actionID: "open:a")
        _ = try await SurfaceCommandService.execute(
            providerID: "homebrew", command: "surface.perform",
            payload: action.encoded(providerID: "homebrew"),
            snapshot: { _ in current }, perform: { performed.append($0) })
        #expect(performed == ["open:a"])
        tile.showActions = false
        let hidden = SurfaceActionRequest(
            snapshot: .init(target: .home, tile: tile), actionID: "open:a")
        await #expect(throws: ExtensionPeerError.self) {
            _ = try await SurfaceCommandService.execute(
                providerID: "homebrew", command: "surface.perform",
                payload: hidden.encoded(providerID: "homebrew"),
                snapshot: { _ in current }, perform: { performed.append($0) })
        }
        #expect(performed == ["open:a"])
    }

    @Test func cancelledRequestCannotChangeState() async throws {
        let tile = SurfaceTile(.ability("keepAwake"))
        let action = SurfaceActionRequest(
            snapshot: .init(target: .home, tile: tile), actionID: "enable")
        var performed = false
        let task = Task {
            _ = try await SurfaceCommandService.execute(
                providerID: "keepAwake", command: "surface.perform",
                payload: action.encoded(providerID: "keepAwake"),
                snapshot: { _ in
                    withUnsafeCurrentTask { $0?.cancel() }
                    return .init(
                        providerID: "keepAwake", actions: [.init("enable", "Enable", "power")])
                }, perform: { _ in performed = true })
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!performed)
    }
    @Test func privacyStopsCollectionAndRejectsActionsBeforeDataCrossesTheBoundary() async throws {
        let tile = SurfaceTile(.ability("colorPicker"))
        var reads = 0
        var actions = 0
        let request = SurfaceSnapshotRequest(target: .home, tile: tile)
        let data = try await SurfaceCommandService.execute(
            providerID: "colorPicker", command: "surface.snapshot",
            payload: request.encoded(providerID: "colorPicker"),
            snapshot: { _ in
                reads += 1
                return .init(providerID: "colorPicker", message: "Private data")
            }, perform: { _ in actions += 1 }, privacyValues: { ["active": "1", "blurShelf": "1"] })
        let masked = try SurfaceSnapshot.decode(data, providerID: "colorPicker")
        #expect(masked.rows.isEmpty && masked.metrics.isEmpty && masked.actions.isEmpty)
        #expect(masked.message == "Hidden while presenting.")
        #expect(reads == 0)
        let action = SurfaceActionRequest(snapshot: request, actionID: "pick")
        await #expect(throws: ExtensionPeerError.self) {
            _ = try await SurfaceCommandService.execute(
                providerID: "colorPicker", command: "surface.perform",
                payload: action.encoded(providerID: "colorPicker"),
                snapshot: { _ in
                    reads += 1
                    return .init(
                        providerID: "colorPicker", actions: [.init("pick", "Pick", "eyedropper")])
                }, perform: { _ in actions += 1 }, privacyValues: { ["active": "1"] })
        }
        #expect(reads == 0 && actions == 0)
    }

    @Test func privacyChangingDuringRefreshNeverReturnsPrivateData() async throws {
        let tile = SurfaceTile(.ability("homebrew"))
        var privateContent = false
        let data = try await SurfaceCommandService.execute(
            providerID: "homebrew", command: "surface.snapshot",
            payload: SurfaceSnapshotRequest(target: .notch, tile: tile).encoded(
                providerID: "homebrew"),
            snapshot: { _ in
                privateContent = true
                return .init(
                    providerID: "homebrew", rows: [.init("secret", title: "Private package")])
            }, perform: { _ in }, privacyValues: { ["active": privateContent ? "1" : "0"] })
        let masked = try SurfaceSnapshot.decode(data, providerID: "homebrew")
        #expect(masked.rows.isEmpty)
        #expect(masked.message == "Hidden while presenting.")
    }

}
