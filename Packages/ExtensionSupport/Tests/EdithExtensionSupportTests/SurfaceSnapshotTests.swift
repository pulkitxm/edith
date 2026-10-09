import Foundation
import Testing

@testable import EdithExtensionSupport

@Suite struct SurfaceSnapshotTests {
    @Test func dataAndOpaqueActionsRoundTripWithoutFeatureTypes() throws {
        let snapshot = SurfaceSnapshot(
            providerID: "calendar", metrics: [.init("meetings", "Upcoming", "2")],
            rows: [
                .init(
                    "meeting", sourceID: "calendar-id", title: "Synthetic meeting",
                    detail: "In 20 minutes", icon: "calendar",
                    actions: [.init("join:meeting", "Join", "video")])
            ],
            sources: [.init("calendar-id", "Synthetic calendar")],
            updatedAt: Date(timeIntervalSince1970: 123))
        #expect(try SurfaceSnapshot.decode(snapshot.encoded(), providerID: "calendar") == snapshot)
        let tile = SurfaceTile(.calendar)
        let request = SurfaceSnapshotRequest(target: .home, tile: tile)
        #expect(
            try SurfaceSnapshotRequest.decode(
                request.encoded(providerID: "calendar"), providerID: "calendar") == request)
        let action = SurfaceActionRequest(snapshot: request, actionID: "join:meeting")
        #expect(
            try SurfaceActionRequest.decode(
                action.encoded(providerID: "calendar"), providerID: "calendar") == action)
    }

    @Test func aProviderCannotServeAnotherExtensionsWidgetOrHiddenTile() throws {
        let request = SurfaceSnapshotRequest(target: .home, tile: .init(.calendar))
        #expect(throws: (any Error).self) { try request.encoded(providerID: "music") }
        var hidden = SurfaceTile(.calendar)
        hidden.hidden = true
        #expect(throws: (any Error).self) {
            try SurfaceSnapshotRequest(target: .home, tile: hidden).encoded(providerID: "calendar")
        }
        let composite = SurfaceSnapshotRequest(target: .notch, tile: .init(.media))
        for provider in ["timeLapse", "downloads", "music", "studio", "virtualCamera"] {
            #expect(
                try SurfaceSnapshotRequest.decode(
                    composite.encoded(providerID: provider), providerID: provider) == composite)
        }
        #expect(throws: (any Error).self) { try composite.encoded(providerID: "clipboard") }
    }

    @Test(arguments: [
        "contract", "provider", "metrics", "rows", "sources", "actions", "text", "fraction",
        "duplicate", "nul",
    ])
    func malformedResponsesNeverReachTheRenderer(mode: String) throws {
        var snapshot = SurfaceSnapshot(providerID: "calendar")
        switch mode {
        case "contract": snapshot.contractVersion = 2
        case "provider": snapshot = SurfaceSnapshot(providerID: "music")
        case "metrics": snapshot.metrics = (0..<33).map { .init(String($0), "Metric", "0") }
        case "rows": snapshot.rows = (0..<101).map { .init(String($0), title: "Row") }
        case "sources": snapshot.sources = (0..<101).map { .init(String($0), "Source") }
        case "actions": snapshot.actions = (0..<9).map { .init(String($0), "Action", "square") }
        case "text": snapshot.message = String(repeating: "x", count: 4097)
        case "fraction": snapshot.metrics = [.init("progress", "Progress", "0", fraction: 2)]
        case "duplicate":
            snapshot.metrics = [.init("same", "Metric", "1"), .init("same", "Metric", "2")]
        default: snapshot.rows = [.init("row", title: "bad\0text")]
        }
        let data = try JSONEncoder().encode(snapshot)
        #expect(throws: (any Error).self) {
            try SurfaceSnapshot.decode(data, providerID: "calendar")
        }
    }

    @Test func excessiveBodiesAndUnsupportedContractsAreRejectedBeforeUse() throws {
        let data = Data(repeating: 32, count: 524_289)
        #expect(throws: (any Error).self) {
            try SurfaceSnapshot.decode(data, providerID: "calendar")
        }
        #expect(throws: (any Error).self) {
            try SurfaceSnapshotRequest.decode(data, providerID: "calendar")
        }
        #expect(throws: (any Error).self) {
            try SurfaceActionRequest.decode(data, providerID: "calendar")
        }
        var request = SurfaceSnapshotRequest(target: .home, tile: .init(.calendar))
        request.contractVersion = 2
        #expect(throws: (any Error).self) {
            try SurfaceSnapshotRequest.decode(JSONEncoder().encode(request), providerID: "calendar")
        }
        let action = SurfaceActionRequest(
            snapshot: .init(target: .home, tile: .init(.calendar)), actionID: "join",
            value: .infinity)
        #expect(throws: (any Error).self) { try action.encoded(providerID: "calendar") }
    }
}
