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
            .agents, .focus, .codeStats, .databases, .machines, .github, .desk, .media,
            .ability("terminal"),
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
        #expect(NotchPanelSlot.supportsSharedCard(.focus))
        #expect(NotchPanelSlot.supportsSharedCard(.agents))
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

    @Test func checkedClientReportsOneAggregateSlotAndTracksCurrentAnchorMeasurements() async throws
    {
        let fixture = try NotchPanelFixture()
        defer { fixture.clean() }
        let tile = saved(.desk)
        var active = ["notchShelf": "1", "clipboard": "1", "emoji": "1"]
        try fixture.publish(active)
        _ = try fixture.attach()
        let controller = fixture.bind()
        controller.layouts.update(.notch) { $0.tiles = [tile] }
        controller.expand(on: 42)
        let client = client(fixture)
        defer { client.stop() }
        await client.refresh()
        #expect(client.supportsNative(tile: tile, kind: .card))
        let rectangle = CGRect(x: 30, y: 80, width: 220, height: 160)
        let original = try #require(client.slot(tile: tile, kind: .card, rectangle: rectangle))
        #expect(original.providerID == "clipboard")
        #expect(original.providerVersion == "1")
        #expect(original.section == "surface.card")
        #expect(original.tile == tile)
        #expect(client.slot(tile: tile, kind: .card, rectangle: rectangle)?.id == original.id)
        try await report(client, slots: [original], fixture: fixture)
        try fixture.engine.measure(
            .init(
                identity: try #require(fixture.engine.identity), displayID: 42,
                presentationID: fixture.presentation, slotID: original.id,
                revision: fixture.engine.revision,
                height: 196, error: "synthetic measured failure"))
        await client.refresh()
        #expect(client.slotHeight(tile: tile, kind: .card) == 196)
        #expect(client.slotFailure(tile: tile, kind: .card) == "synthetic measured failure")
        active["clipboard"] = nil
        try fixture.publish(active)
        controller.synchronize()
        await client.refresh()
        let next = try #require(client.slot(tile: tile, kind: .card, rectangle: rectangle))
        #expect(next.providerID == "emoji")
        #expect(next.id != original.id)
        #expect(client.slotHeight(tile: tile, kind: .card) == nil)
        #expect(client.slotFailure(tile: tile, kind: .card) == nil)
        try await report(client, slots: [next], fixture: fixture)
        active["emoji"] = "2"
        try fixture.publish(active)
        controller.synchronize()
        await client.refresh()
        let updated = try #require(client.slot(tile: tile, kind: .card, rectangle: rectangle))
        #expect(updated.providerVersion == "2")
        #expect(updated.tile == tile)
        #expect(throws: (any Error).self) { try fixture.geometry([next]) }
        try await report(client, slots: [updated], fixture: fixture)
        var unsaved = tile
        unsaved.showTitle.toggle()
        #expect(client.slot(tile: unsaved, kind: .card, rectangle: rectangle) == nil)
        #expect(
            client.slot(
                tile: tile, kind: .card, rectangle: .init(x: 5000, y: 0, width: 10, height: 10))
                == nil)
        #expect(
            client.slot(
                tile: tile, kind: .card,
                rectangle: .init(x: 0, y: 0, width: CGFloat.infinity, height: 10))
                == nil)
        #expect(client.slot(tile: tile, kind: .providerTab, rectangle: rectangle) == nil)
        #expect(client.supportsNative(tile: tile, kind: .providerTab) == false)
        #expect(controller.surfaceLayout.tiles == [tile])
    }

    @Test func privacyCollapseAndDisableRemoveSharedCardAdmissionAndOwnedMeasurements() async throws
    {
        let fixture = try NotchPanelFixture()
        defer { fixture.clean() }
        let tile = saved(.desk)
        let active = versions(for: [tile])
        try fixture.publish(active)
        let identity = try fixture.attach().identity
        let controller = fixture.bind()
        controller.layouts.update(.notch) { $0.tiles = [tile] }
        controller.expand(on: 42)
        let client = client(fixture)
        defer { client.stop() }
        await client.refresh()
        let rectangle = CGRect(x: 30, y: 80, width: 220, height: 160)
        let original = try #require(client.slot(tile: tile, kind: .card, rectangle: rectangle))
        try await report(client, slots: [original], fixture: fixture)
        try fixture.engine.measure(
            .init(
                identity: identity, displayID: 42,
                presentationID: fixture.presentation, slotID: original.id,
                revision: fixture.engine.revision,
                height: 200, error: nil))
        let privacy = ExtensionSharedState(
            root: fixture.root, namespace: fixture.id, owner: "presenter")
        try privacy.publish(["active": "1", "blurShelf": "1"])
        controller.synchronize()
        await client.refresh()
        #expect(client.hides(.desk))
        try await report(client, slots: [], fixture: fixture)
        #expect(client.slot(tile: tile, kind: .card, rectangle: rectangle) == nil)
        #expect(client.slotHeight(tile: tile, kind: .card) == nil)
        #expect(try fixture.engine.batch().states[0].slots.isEmpty)
        #expect(throws: (any Error).self) { try fixture.geometry([original]) }
        try privacy.publish(["active": "0"])
        controller.synchronize()
        await client.refresh()
        let visible = try #require(client.slot(tile: tile, kind: .card, rectangle: rectangle))
        try await report(client, slots: [visible], fixture: fixture)
        controller.collapseNow()
        await client.refresh()
        try await report(client, slots: [], fixture: fixture)
        #expect(client.slot(tile: tile, kind: .card, rectangle: rectangle) == nil)
        #expect(try fixture.engine.batch().states[0].slots.isEmpty)
        controller.expand(on: 42)
        await client.refresh()
        let expanded = try #require(client.slot(tile: tile, kind: .card, rectangle: rectangle))
        try await report(client, slots: [expanded], fixture: fixture)
        try fixture.publish(["notchShelf": "1"])
        controller.synchronize()
        await client.refresh()
        #expect(client.supportsNative(tile: tile, kind: .card) == false)
        try await report(client, slots: [], fixture: fixture)
        #expect(client.slot(tile: tile, kind: .card, rectangle: rectangle) == nil)
        #expect(try fixture.engine.batch().states[0].slots.isEmpty)
        try fixture.publish(active)
        controller.synchronize()
        await client.refresh()
        let restored = try #require(client.slot(tile: tile, kind: .card, rectangle: rectangle))
        try await report(client, slots: [restored], fixture: fixture)
        var disabled = active
        disabled["notchShelf"] = nil
        try fixture.publish(disabled)
        controller.synchronize()
        await client.refresh()
        #expect(client.error != nil)
        #expect(client.slot(tile: tile, kind: .card, rectangle: rectangle) == nil)
        #expect(try fixture.engine.batch().states[0].slots.isEmpty)
        #expect(throws: (any Error).self) { try fixture.geometry([restored]) }
        try fixture.engine.detach(identity)
        await client.stopAndWait()
        #expect(client.slot(tile: tile, kind: .card, rectangle: rectangle) == nil)
        #expect(client.slotHeight(tile: tile, kind: .card) == nil)
        #expect(!client.supportsNative(tile: tile, kind: .card))
        #expect(controller.ownedPanelCount == 0)
    }

    @Test func customAgentsAndFocusUseOnlyCurrentOwnedVisibleProviderSlots() async throws {
        let fixture = try NotchPanelFixture()
        defer { fixture.clean() }
        let tiles = [saved(.agents), saved(.focus)]
        var active = versions(for: tiles)
        try fixture.publish(active)
        let identity = try fixture.attach().identity
        let controller = fixture.bind()
        controller.layouts.update(.notch) { $0.tiles = tiles }
        controller.expand(on: 42)
        let chrome = client(fixture)
        defer { chrome.stop() }
        await chrome.refresh()
        let rectangle = CGRect(x: 30, y: 80, width: 220, height: 160)
        for tile in tiles {
            let provider = tile.widget == .agents ? "herdr" : "attention"
            #expect(chrome.supportsNative(tile: tile, kind: .card))
            let accepted = try #require(chrome.slot(tile: tile, kind: .card, rectangle: rectangle))
            #expect(accepted.providerID == provider && accepted.providerVersion == "1")
            #expect(accepted.tile == tile && accepted.section == "surface.card")
            try fixture.geometry([accepted])
            #expect(throws: (any Error).self) {
                try fixture.geometry([
                    slot(tile, provider: provider == "herdr" ? "attention" : "herdr")
                ])
            }
            #expect(throws: (any Error).self) {
                try fixture.geometry([slot(tile, provider: provider, version: "stale")])
            }
            #expect(throws: (any Error).self) {
                try fixture.geometry([accepted, slot(tile, provider: provider)])
            }
            var changed = tile
            changed.focusMinutes += 1
            #expect(throws: (any Error).self) {
                try fixture.geometry([slot(changed, provider: provider)])
            }
            active[provider] = "2"
            try fixture.publish(active)
            controller.synchronize()
            await chrome.refresh()
            #expect(try fixture.engine.batch().states[0].slots.isEmpty)
            #expect(throws: (any Error).self) { try fixture.geometry([accepted]) }
            let updated = try #require(chrome.slot(tile: tile, kind: .card, rectangle: rectangle))
            #expect(updated.providerVersion == "2" && updated.tile == tile)
            try fixture.geometry([updated])
            active[provider] = nil
            try fixture.publish(active)
            controller.synchronize()
            await chrome.refresh()
            #expect(!chrome.supportsNative(tile: tile, kind: .card))
            #expect(chrome.slot(tile: tile, kind: .card, rectangle: rectangle) == nil)
            #expect(try fixture.engine.batch().states[0].slots.isEmpty)
            active[provider] = "1"
            try fixture.publish(active)
            controller.synchronize()
            await chrome.refresh()
            let privacy = ExtensionSharedState(
                root: fixture.root, namespace: fixture.id, owner: "presenter")
            let category = tile.widget == .agents ? "blurAgents" : "blurAttention"
            try privacy.publish(["active": "1", category: "1"])
            controller.synchronize()
            await chrome.refresh()
            #expect(chrome.hides(tile.widget))
            #expect(chrome.slot(tile: tile, kind: .card, rectangle: rectangle) == nil)
            #expect(throws: (any Error).self) { try fixture.geometry([accepted]) }
            try privacy.publish(["active": "0"])
            controller.synchronize()
            await chrome.refresh()
        }
        controller.collapseNow()
        await chrome.refresh()
        #expect(
            tiles.allSatisfy { chrome.slot(tile: $0, kind: .card, rectangle: rectangle) == nil })
        #expect(try fixture.engine.batch().states[0].slots.isEmpty)
        #expect(controller.surfaceLayout.tiles == tiles)
        try fixture.engine.detach(identity)
        await chrome.stopAndWait()
        #expect(controller.ownedPanelCount == 0)
    }

    @Test func originalHomeMeasuresSharedAggregateCardsOffscreenAtBothLayoutsAndZooms() async throws
    {
        let fixture = try NotchPanelFixture()
        defer { fixture.clean() }
        let tiles = [saved(.agents), saved(.focus)]
        try fixture.publish(versions(for: tiles))
        _ = try fixture.attach()
        let controller = fixture.bind()
        controller.expand(on: 42)
        let client = client(fixture)
        defer { client.stop() }
        let scale = UIScale.current
        defer { UIScale.apply(scale) }
        for horizontal in [false, true] {
            for (width, zoom) in [(540.0, 1.0), (960.0, 1.5)] {
                UIScale.apply(zoom)
                controller.layouts.update(.notch) {
                    $0.tiles = tiles
                    $0.notchHorizontal = horizontal
                }
                await client.refresh()
                var measured: [NotchPanelSlot] = []
                let host = NSHostingView(
                    rootView: NotchHomeTab(controller: client)
                        .coordinateSpace(name: "notchPanel")
                        .environment(\.automaticViewActionsEnabled, false)
                        .onPreferenceChange(NotchSlotFrames.self) { measured = $0 }
                        .transaction { $0.animation = nil })
                host.frame = CGRect(x: 0, y: 0, width: width, height: 700)
                let window = TestWindowHost.window(contentRect: host.frame)
                window.contentView = host
                defer { window.contentView = nil }
                for _ in 0..<20 {
                    window.layoutIfNeeded(); host.layoutSubtreeIfNeeded()
                    if measured.count == tiles.count { break }
                    try await Task.sleep(for: .milliseconds(10))
                }
                #expect(measured.count == tiles.count)
                #expect(Set(measured.map { $0.tile.id }) == Set(tiles.map(\.id)))
                #expect(
                    measured.allSatisfy { $0.section == "surface.card" && tiles.contains($0.tile) })
                #expect(
                    measured.allSatisfy {
                        $0.rectangle.valid && host.bounds.contains($0.rectangle.frame)
                    })
                try await report(client, slots: measured, fixture: fixture)
                #expect(try fixture.engine.batch().states[0].slots.count == tiles.count)
                #expect(!window.isVisible)
                #expect(!TestWindowHost.isExposedOnDesktop(window))
                #expect(controller.requests.pendingCount == 0)
            }
        }
        #expect(client.surfaceClient == nil)
    }

    private func client(_ fixture: NotchPanelFixture) -> NotchChromeClient {
        NotchChromeClient(
            displayID: 42, presentationID: fixture.presentation, namespace: fixture.id
        ) {
            operation, payload in
            switch operation {
            case "notch.chrome.read":
                return try JSONEncoder().encode(
                    fixture.engine.chrome(JSONDecoder().decode(NotchChromeRead.self, from: payload))
                )
            case "notch.chrome.action":
                let request = try JSONDecoder().decode(NotchChromeAction.self, from: payload)
                try fixture.engine.action(request)
                return try JSONEncoder().encode(
                    fixture.engine.chrome(
                        .init(displayID: request.displayID, presentationID: request.presentationID))
                )
            case "notch.panel.geometry":
                try fixture.engine.geometry(
                    JSONDecoder().decode(NotchPanelGeometry.self, from: payload))
                return Data("{}".utf8)
            default: throw ExtensionPeerError.invalidRequest
            }
        }
    }

    private func report(
        _ client: NotchChromeClient, slots: [NotchPanelSlot], fixture: NotchPanelFixture
    ) async throws {
        client.report(slots)
        await Task.yield()
        for _ in 0..<50 {
            let actual = try fixture.engine.batch().states[0].slots
            if actual.count == slots.count, slots.allSatisfy(actual.contains) { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(try fixture.engine.batch().states[0].slots.count == slots.count)
        #expect(client.error == nil)
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
