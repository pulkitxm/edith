import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import SwiftUI
import Testing
@testable import NotchShelfExtension

@MainActor @Suite(.serialized) struct NotchSharedCardSlotTests {
    @Test func sharedCardsRetainEverySavedTileFieldAndOneSlotPerAggregate() throws {
        let fixture = try NotchPanelFixture()
        defer { fixture.clean() }
        let tiles = [
            .codeStats, .databases, .machines, .github, .desk, .media, .ability("terminal"),
        ].map(saved)
        try fixture.publish(versions(for: tiles))
        _ = try fixture.attach()
        let controller = fixture.bind()
        controller.layouts.update(.notch) { $0.tiles = tiles }
        controller.expand(on: 42)
        let slots = tiles.map { slot($0, provider: $0.widget.providerIDs.sorted()[0]) }
        try fixture.geometry(slots)
        let state = try fixture.engine.batch().states[0]
        #expect(state.slots == slots)
        #expect(state.slots.count == tiles.count)
        #expect(state.slots.allSatisfy { $0.section == "surface.card" })
        #expect(state.slots.map(\.tile) == tiles)
        #expect(controller.surfaceLayout.tiles == tiles)
        let encoded = try JSONEncoder().encode(try fixture.engine.batch())
        #expect(
            try JSONDecoder().decode(NotchPanelBatch.self, from: encoded).states[0].slots == slots)
        for card in slots {
            let request = SurfaceSnapshotRequest(target: .notch, tile: card.tile)
            #expect(try request.encoded(providerID: card.providerID).isEmpty == false)
        }
        #expect(controller.ownedPanelCount == 0)
    }

    @Test func geometryRejectsForeignNonFirstDuplicateChangedHiddenAndUnboundedCards() throws {
        let fixture = try NotchPanelFixture()
        defer { fixture.clean() }
        let tile = saved(.desk)
        try fixture.publish(versions(for: [tile]))
        let identity = try fixture.attach().identity
        let controller = fixture.bind()
        controller.layouts.update(.notch) { $0.tiles = [tile] }
        controller.expand(on: 42)
        let anchor = tile.widget.providerIDs.sorted()[0]
        let accepted = slot(tile, provider: anchor)
        try fixture.geometry([accepted])
        for foreign in tile.widget.providerIDs.sorted().dropFirst() + ["calendar"] {
            #expect(throws: (any Error).self) {
                try fixture.geometry([slot(tile, provider: foreign)])
            }
        }
        let duplicate = slot(tile, provider: anchor)
        #expect(throws: (any Error).self) { try fixture.geometry([accepted, duplicate]) }
        var changed = tile
        changed.showActions.toggle()
        #expect(throws: (any Error).self) {
            try fixture.geometry([slot(changed, provider: anchor)])
        }
        changed = tile; changed.hidden = true
        #expect(throws: (any Error).self) {
            try fixture.geometry([slot(changed, provider: anchor)])
        }
        changed = tile; changed.instanceID = "unsaved-instance"
        #expect(throws: (any Error).self) {
            try fixture.geometry([slot(changed, provider: anchor)])
        }
        #expect(throws: (any Error).self) {
            try fixture.geometry([slot(tile, provider: anchor, version: "foreign-version")])
        }
        for rectangle in [
            NotchPanelRectangle(x: -1, y: 20, width: 220, height: 160),
            .init(x: 30, y: 80, width: 3000, height: 160),
            .init(x: 30, y: 80, width: .nan, height: 160),
        ] {
            #expect(throws: (any Error).self) {
                try fixture.geometry([slot(tile, provider: anchor, rectangle: rectangle)])
            }
        }
        for stale in [
            NotchPanelIdentity(ownershipID: UUID(), generation: identity.generation),
            .init(ownershipID: identity.ownershipID, generation: UUID()),
        ] {
            #expect(throws: (any Error).self) {
                try fixture.engine.geometry(
                    .init(
                        identity: stale, displayID: 42, presentationID: fixture.presentation,
                        revision: fixture.engine.revision, layout: controller.surfaceLayout,
                        slots: [accepted]))
            }
        }
        #expect(try fixture.engine.batch().states[0].slots == [accepted])
    }

    @Test func currentFirstActiveAnchorAndVersionPruneStaleAggregateGeometry() throws {
        let fixture = try NotchPanelFixture()
        defer { fixture.clean() }
        let tile = saved(.media)
        var active = versions(for: [tile])
        try fixture.publish(active)
        _ = try fixture.attach()
        let controller = fixture.bind()
        controller.layouts.update(.notch) { $0.tiles = [tile] }
        controller.expand(on: 42)
        let providers = tile.widget.providerIDs.sorted()
        let original = slot(tile, provider: providers[0])
        try fixture.geometry([original])
        active[providers[0]] = nil
        try fixture.publish(active)
        controller.synchronize()
        #expect(try fixture.engine.batch().states[0].slots.isEmpty)
        #expect(throws: (any Error).self) { try fixture.geometry([original]) }
        let replacement = slot(tile, provider: providers[1])
        try fixture.geometry([replacement])
        active[providers[1]] = "2"
        try fixture.publish(active)
        controller.synchronize()
        #expect(try fixture.engine.batch().states[0].slots.isEmpty)
        #expect(throws: (any Error).self) { try fixture.geometry([replacement]) }
        let updated = slot(tile, provider: providers[1], version: "2")
        try fixture.geometry([updated])
        #expect(try fixture.engine.batch().states[0].slots == [updated])
        active[providers[0]] = "3"
        try fixture.publish(active)
        controller.synchronize()
        #expect(try fixture.engine.batch().states[0].slots.isEmpty)
        #expect(throws: (any Error).self) { try fixture.geometry([updated]) }
        try fixture.geometry([slot(tile, provider: providers[0], version: "3")])
        #expect(controller.surfaceLayout.tiles == [tile])
    }

    @Test func specialNativeSectionsAndNonCardSingleProviderRulesRemainStrict() throws {
        let fixture = try NotchPanelFixture()
        defer { fixture.clean() }
        let tiles = [
            SurfaceTile(.music), .init(.calendar), .init(.usage), .init(.activity), .init(.limits),
        ]
        try fixture.publish(versions(for: tiles))
        _ = try fixture.attach()
        let controller = fixture.bind()
        controller.layouts.update(.notch) { $0.tiles = tiles }
        controller.expand(on: 42)
        let slots = tiles.map { slot($0, provider: $0.widget.providerIDs.first!) }
        try fixture.geometry(slots)
        #expect(slots.map(\.section) == ["music", "calendar", "usage", "activity", "limits"])
        #expect(NotchPanelSlot.supportsSharedCard(.focus) == false)
        #expect(NotchPanelSlot.supportsSharedCard(.agents) == false)
        for kind in [
            NotchPanelSlot.Kind.providerTab, .header, .collapsedLeading, .collapsedTrailing,
        ] {
            #expect(
                NotchPanelSlot.anchorProvider(
                    tile: SurfaceTile(.media), kind: kind,
                    activeVersions: fixture.context.activeVersions) == nil)
            #expect(slot(SurfaceTile(.media), provider: "music", kind: kind).section == nil)
        }
        let audio = SurfaceTile(.ability("audioMixer"))
        #expect(slot(audio, provider: "audioMixer").section == "surface.card")
        #expect(slot(audio, provider: "audioMixer", kind: .providerTab).section == "audioMixer")
        #expect(
            slot(SurfaceTile(.agents), provider: "herdr", kind: .providerTab).section == "agents")
        #expect(
            slot(SurfaceTile(.music), provider: "music", kind: .header).section == "music.header")
        #expect(
            slot(SurfaceTile(.music), provider: "music", kind: .collapsedLeading).section
                == "music.glance.leading")
    }

    private func saved(_ widget: SurfaceWidget) -> SurfaceTile {
        var tile = SurfaceTile(widget)
        tile.instanceID = widget.rawValue + "-saved"
        tile.title = "Synthetic saved card"
        tile.locked = true
        tile.dense = true
        tile.showActions = false
        tile.showDetails = false
        tile.itemLimit = 3
        tile.days = 7
        tile.span = 12
        tile.hiddenFields = ["synthetic-hidden"]
        tile.sourceIDs = ["synthetic-source"]
        tile.contentKinds = ["synthetic-kind"]
        tile.paddingOverride = 10
        tile.cornerOverride = 8
        tile.shelfWidth = 240
        return tile
    }

    private func versions(for tiles: [SurfaceTile]) -> [String: String] {
        var values = ["notchShelf": "1"]
        for tile in tiles { for id in tile.widget.providerIDs { values[id] = "1" } }
        return values
    }

    private func slot(
        _ tile: SurfaceTile, provider: String, version: String = "1",
        kind: NotchPanelSlot.Kind = .card,
        rectangle: NotchPanelRectangle = .init(x: 30, y: 80, width: 220, height: 160)
    ) -> NotchPanelSlot {
        .init(
            id: UUID(), providerID: provider, providerVersion: version, kind: kind, tile: tile,
            rectangle: rectangle)
    }
}
