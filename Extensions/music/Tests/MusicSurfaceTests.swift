import AppKit
import EdithExtensionSupport
import Foundation
import Testing

@testable import MusicExtension

extension MusicExtensionTests {
    @MainActor @Suite struct MusicSurfaceTests {
        @Test func snapshotKeepsOpaqueTrackIdentityAndRealPlaybackControls() async throws {
            let fixture = Fixture()
            let snapshot = try await fixture.snapshot()
            #expect(snapshot.rows.first?.title == "Mock Track")
            #expect(snapshot.rows.first?.detail == "Mock Artist")
            #expect(snapshot.rows.first?.progress == 0.25)
            #expect(snapshot.rows.first?.actions.count == 8)
            #expect(snapshot.rows.first?.sliders?.map(\.value) == [0.25, 0.6])
            let wire = String(decoding: try snapshot.encoded(), as: UTF8.self)
            #expect(!wire.contains("private-library"))
            #expect(!wire.contains("up-next.m4a"))
        }

        @Test func sourceSelectionLimitsRowsAndRejectsOtherPlayersActions() async throws {
            let fixture = Fixture()
            fixture.states.append(
                .init(
                    sourceID: "spotify", sourceTitle: "Spotify", trackKey: "spotify:mock",
                    title: "Other Mock Track"))
            fixture.tile.sourceIDs = ["local"]
            let snapshot = try await fixture.snapshot()
            #expect(snapshot.sources.count == 2)
            #expect(snapshot.rows.allSatisfy { $0.sourceID == "local" })
            await #expect(throws: ExtensionPeerError.self) {
                _ = try await fixture.action(fixture.states[1].identifier("open"))
            }
            #expect(fixture.commands.isEmpty)
        }

        @Test func homeKeepsSimpleTransportAndNotchOffersDetailedControls() async throws {
            let fixture = Fixture()
            let home = try await fixture.snapshot(target: .home)
            #expect(home.rows[0].actions.count == 4)
            #expect(home.rows[0].sliders == nil)
            let notch = try await fixture.snapshot()
            #expect(notch.rows[0].actions.contains { $0.field == "shuffle" })
            #expect(notch.rows[0].sliders?.contains { $0.field == "volume" } == true)
            await #expect(throws: ExtensionPeerError.self) {
                _ = try await fixture.action(
                    fixture.states[0].identifier("volume"), value: 0.4, target: .home)
            }
        }

        @Test func hiddenFieldsRemoveArtistTimeQueueAndControlsAtTheBoundary() async throws {
            let fixture = Fixture()
            fixture.tile.hiddenFields = [
                "artist", "progress", "queue", "volume", "shuffle", "repeat", "seekControls",
            ]
            let snapshot = try await fixture.snapshot()
            #expect(snapshot.rows.count == 1)
            #expect(snapshot.rows[0].detail.isEmpty)
            #expect(snapshot.rows[0].value == "Playing")
            #expect(snapshot.rows[0].progress == nil)
            #expect(snapshot.rows[0].sliders == nil)
            #expect(snapshot.rows[0].actions.count == 4)
            await #expect(throws: ExtensionPeerError.self) {
                _ = try await fixture.action(fixture.states[0].identifier("shuffle"))
            }
        }

        @Test func slidersDispatchOnlyBoundedCurrentPlaybackValues() async throws {
            let fixture = Fixture()
            _ = try await fixture.action(fixture.states[0].identifier("seek"), value: 0.4)
            #expect(
                fixture.commands == [
                    .init(
                        sourceID: "local", trackKey: "private-library/song.m4a", action: "seek",
                        value: 0.4)
                ])
            await #expect(throws: ExtensionPeerError.self) {
                _ = try await fixture.action(fixture.states[0].identifier("seek"))
            }
            await #expect(throws: ExtensionPeerError.self) {
                _ = try await fixture.action(fixture.states[0].identifier("toggle"), value: 0.4)
            }
            #expect(fixture.commands.count == 1)
        }

        @Test func trackChangesRejectThePreviousTracksOpaqueAction() async throws {
            let fixture = Fixture()
            let old = fixture.states[0].identifier("toggle")
            fixture.states[0].trackKey = "private-library/new-track.m4a"
            await #expect(throws: ExtensionPeerError.self) { _ = try await fixture.action(old) }
            #expect(fixture.commands.isEmpty)
        }

        @Test func queuedPlaybackUsesTheCurrentQueueAndNeverAcceptsAnArbitraryPath() async throws {
            let fixture = Fixture()
            let track = fixture.states[0].queue[0]
            _ = try await fixture.action(fixture.states[0].queuedIdentifier(track))
            #expect(fixture.commands.last?.trackKey == track.key)
            #expect(fixture.commands.last?.action == "playQueue")
            fixture.states[0].queue.removeAll()
            await #expect(throws: ExtensionPeerError.self) {
                _ = try await fixture.action(fixture.states[0].queuedIdentifier(track))
            }
            #expect(fixture.commands.count == 1)
        }

        @Test func disabledActionsRemoveButtonsAndSlidersAndRejectMutations() async throws {
            let fixture = Fixture()
            fixture.tile.showActions = false
            let snapshot = try await fixture.snapshot()
            #expect(snapshot.rows.allSatisfy { $0.actions.isEmpty && $0.sliders == nil })
            await #expect(throws: ExtensionPeerError.self) {
                _ = try await fixture.action(fixture.states[0].identifier("toggle"))
            }
        }

        @Test func presenterModeSkipsDataReadsAndRejectsMusicActions() async throws {
            let fixture = Fixture()
            fixture.privacy = ["active": "1", "blurMusic": "1"]
            let snapshot = try await fixture.snapshot()
            #expect(snapshot.rows.isEmpty && snapshot.sources.isEmpty)
            #expect(fixture.reads == 0)
            await #expect(throws: ExtensionPeerError.self) {
                _ = try await fixture.action(fixture.states[0].identifier("toggle"))
            }
            #expect(fixture.commands.isEmpty && fixture.reads == 0)
        }

        @Test func privacyChangesDuringReadPreventActionsAndPrivateResponses() async throws {
            let fixture = Fixture()
            fixture.hideDuringRead = true
            let snapshot = try await fixture.snapshot()
            #expect(snapshot.rows.isEmpty)
            fixture.privacy = [:]
            await #expect(throws: ExtensionPeerError.self) {
                _ = try await fixture.action(fixture.states[0].identifier("toggle"))
            }
            #expect(fixture.commands.isEmpty)
        }

        @Test func artworkIsBoundedAndFollowsItsOwnVisibilityField() async throws {
            let fixture = Fixture()
            let bitmap = try #require(
                NSBitmapImageRep(
                    bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8,
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            fixture.states[0].thumbnail = .init(
                data: data, accessibilityLabel: "Mock artwork", field: "artwork")
            #expect(try await fixture.snapshot().rows[0].thumbnail?.data == data)
            fixture.tile.hiddenFields = ["artwork"]
            #expect(try await fixture.snapshot().rows[0].thumbnail == nil)
        }

        @MainActor private final class Fixture {
            var tile = SurfaceTile(.music)
            var states = [
                MusicSurfacePlayback(
                    sourceID: "local", sourceTitle: "Local library",
                    trackKey: "private-library/song.m4a", title: "Mock Track",
                    artist: "Mock Artist",
                    playing: true, elapsed: 30, duration: 120, volume: 0.6, shuffle: false,
                    repeating: true,
                    queue: [.init(key: "private-library/up-next.m4a", title: "Next Mock Track")])
            ]
            var commands: [MusicSurfaceCommand] = []
            var privacy: [String: String] = [:]
            var reads = 0
            var hideDuringRead = false
            lazy var surface = MusicSurface(
                read: { [self] _ in
                    reads += 1
                    if hideDuringRead { privacy = ["active": "1", "blurMusic": "1"] }
                    return states
                }, perform: { [self] in commands.append($0) }, privacyValues: { [self] in privacy })

            func snapshot(target: SurfaceTarget = .notch) async throws -> SurfaceSnapshot {
                let request = SurfaceSnapshotRequest(target: target, tile: tile)
                return try SurfaceSnapshot.decode(
                    await surface.execute(
                        "surface.snapshot", payload: request.encoded(providerID: "music")),
                    providerID: "music")
            }
            func action(_ id: String, value: Double? = nil, target: SurfaceTarget = .notch)
                async throws -> SurfaceSnapshot
            {
                let request = SurfaceActionRequest(
                    snapshot: .init(target: target, tile: tile), actionID: id, value: value)
                return try SurfaceSnapshot.decode(
                    await surface.execute(
                        "surface.perform", payload: request.encoded(providerID: "music")),
                    providerID: "music")
            }
        }
    }
}
