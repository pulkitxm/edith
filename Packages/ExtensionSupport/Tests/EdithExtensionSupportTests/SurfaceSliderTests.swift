import Foundation
import Testing
@testable import EdithExtensionSupport

@Suite @MainActor
struct SurfaceSliderTests {
    @Test func controlsRoundTripWithoutChangingButtonOnlySnapshots() throws {
        let old = SurfaceSnapshot(
            providerID: "music", rows: [.init("track", title: "Synthetic track")])
        let oldData = try old.encoded()
        #expect(!String(decoding: oldData, as: UTF8.self).contains("sliders"))
        #expect(try SurfaceSnapshot.decode(oldData, providerID: "music").sliders == nil)
        let controls = SurfaceSnapshot(
            providerID: "music",
            sliders: [.init("volume", "Volume", "speaker.wave.2", value: 0.7, field: "volume")])
        #expect(try SurfaceSnapshot.decode(controls.encoded(), providerID: "music") == controls)
    }

    @Test(arguments: [-0.1, 1.1, Double.infinity, Double.nan])
    func invalidValuesNeverEncode(_ value: Double) {
        let snapshot = SurfaceSnapshot(
            providerID: "music", sliders: [.init("volume", "Volume", "speaker", value: value)])
        #expect(throws: ExtensionPeerError.self) { _ = try snapshot.encoded() }
    }

    @Test func duplicateControlsAndButtonCollisionsAreRejectedAcrossRows() {
        let collision = SurfaceSnapshot(
            providerID: "music", actions: [.init("volume", "Play", "play")],
            sliders: [.init("volume", "Volume", "speaker", value: 0.4)])
        #expect(throws: ExtensionPeerError.self) { _ = try collision.encoded() }
        let rows = SurfaceSnapshot(
            providerID: "audioMixer",
            rows: [
                .init(
                    "one", title: "First",
                    sliders: [.init("volume", "Volume", "speaker", value: 0.4)]),
                .init(
                    "two", title: "Second",
                    sliders: [.init("volume", "Volume", "speaker", value: 0.8)]),
            ])
        #expect(throws: ExtensionPeerError.self) { _ = try rows.encoded() }
        let tooMany = SurfaceSnapshot(
            providerID: "music",
            sliders: (0..<33).map { .init($0.description, "Volume", "speaker", value: 0.5) })
        #expect(throws: ExtensionPeerError.self) { _ = try tooMany.encoded() }
    }

    @Test func sliderValuesAreValidatedAgainstCurrentFieldsAndSelectionBeforeMutation() async throws
    {
        var tile = SurfaceTile(.ability("audioMixer"))
        tile.sourceIDs = ["first"]
        let snapshot = SurfaceSnapshot(
            providerID: "audioMixer",
            rows: [
                .init(
                    "one", sourceID: "first", title: "First",
                    sliders: [.init("volume:one", "Volume", "speaker", value: 0.4, field: "volume")]
                ),
                .init(
                    "two", sourceID: "second", title: "Second",
                    sliders: [.init("volume:two", "Volume", "speaker", value: 0.8, field: "volume")]
                ),
            ])
        var adjusted: [(String, Double)] = []
        let request = SurfaceActionRequest(
            snapshot: .init(target: .notch, tile: tile), actionID: "volume:one", value: 0.9)
        _ = try await SurfaceCommandService.execute(
            providerID: "audioMixer", command: "surface.perform",
            payload: request.encoded(providerID: "audioMixer"), snapshot: { _ in snapshot },
            perform: { _ in Issue.record("Slider invoked a button") },
            adjust: { adjusted.append(($0, $1)) })
        #expect(
            adjusted.count == 1 && adjusted.first?.0 == "volume:one" && adjusted.first?.1 == 0.9)
        tile.hiddenFields = ["volume"]
        let hidden = SurfaceActionRequest(
            snapshot: .init(target: .home, tile: tile), actionID: "volume:one", value: 0.2)
        await #expect(throws: ExtensionPeerError.self) {
            _ = try await SurfaceCommandService.execute(
                providerID: "audioMixer", command: "surface.perform",
                payload: hidden.encoded(providerID: "audioMixer"), snapshot: { _ in snapshot },
                perform: { _ in }, adjust: { adjusted.append(($0, $1)) })
        }
        #expect(adjusted.count == 1)
        let missing = SurfaceActionRequest(
            snapshot: .init(target: .home, tile: .init(.ability("audioMixer"))),
            actionID: "volume:one")
        await #expect(throws: ExtensionPeerError.self) {
            _ = try await SurfaceCommandService.execute(
                providerID: "audioMixer", command: "surface.perform",
                payload: missing.encoded(providerID: "audioMixer"), snapshot: { _ in snapshot },
                perform: { _ in }, adjust: { adjusted.append(($0, $1)) })
        }
    }

    @Test func sharedClientRejectsUnselectedAndHiddenControlsBeforeSendingAnyRequest() async throws
    {
        let sent = SurfaceControlRequests()
        let snapshot = SurfaceSnapshot(
            providerID: "music",
            sliders: [.init("volume", "Volume", "speaker", value: 0.7, field: "volume")])
        let client = SurfaceSnapshotClient(
            activeVersions: { ["music": "1"] },
            execute: { _, _, data in
                await sent.record(data); return try snapshot.encoded()
            })
        defer { client.shutdown() }
        var tile = SurfaceTile(.music)
        tile.hiddenFields = ["volume"]
        await #expect(throws: ExtensionPeerError.self) {
            _ = try await client.perform(
                providerID: "music", target: .home, tile: tile, snapshot: snapshot,
                actionID: "volume", value: 0.8)
        }
        #expect(await sent.count == 0)
        tile.hiddenFields = []
        _ = try await client.perform(
            providerID: "music", target: .home, tile: tile, snapshot: snapshot, actionID: "volume",
            value: 0.8)
        #expect(await sent.count == 1)
        let encoded = try #require(await sent.last)
        #expect(try SurfaceActionRequest.decode(encoded, providerID: "music").value == 0.8)
    }

    @Test func privacyNeverPublishesControlsOrAcceptsTheirValues() async throws {
        let snapshot = SurfaceSnapshot(
            providerID: "music", sliders: [.init("volume", "Volume", "speaker", value: 0.7)])
        let request = SurfaceSnapshotRequest(target: .home, tile: .init(.music))
        let data = try await SurfaceCommandService.execute(
            providerID: "music", command: "surface.snapshot",
            payload: request.encoded(providerID: "music"), snapshot: { _ in snapshot },
            perform: { _ in }, privacyValues: { ["active": "1", "blurMusic": "1"] })
        #expect(try SurfaceSnapshot.decode(data, providerID: "music").sliders == nil)
        let action = SurfaceActionRequest(snapshot: request, actionID: "volume", value: 0.3)
        await #expect(throws: ExtensionPeerError.self) {
            _ = try await SurfaceCommandService.execute(
                providerID: "music", command: "surface.perform",
                payload: action.encoded(providerID: "music"), snapshot: { _ in snapshot },
                perform: { _ in }, adjust: { _, _ in Issue.record("Private control mutated") },
                privacyValues: { ["active": "1"] })
        }
    }
}

private actor SurfaceControlRequests {
    var count = 0
    var last: Data?
    func record(_ data: Data) { count += 1; last = data }
}
