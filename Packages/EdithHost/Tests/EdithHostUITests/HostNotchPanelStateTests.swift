import CoreGraphics
import EdithExtensionSupport
import EdithHostCore
import Foundation
import Testing

@testable import EdithHost

struct HostNotchPanelStateTests {
    @Test func actualCalendarNotchRoutePreservesOriginalTileAndEightSceneCapacity() throws {
        let fixture = HostNotchStateFixture()
        var tile = SurfaceTile(.calendar)
        tile.title = "Synthetic meetings"
        tile.itemLimit = 3
        let slot = fixture.slot(provider: "calendar", tile: tile)
        let state = fixture.state(slots: [slot])
        let request = try slot.request(presentationID: UUID())
        #expect(request.location == "notch" && request.section == "calendar")
        #expect(request.surface?.target == .notch && request.surface?.tile == tile)
        try state.validate(
            fixture.admission(
                active: ["notchShelf": "1.0.0", "calendar": "1.0.0"],
                layout: .init(tiles: [tile]), reserved: ["calendar": 7]))
        #expect(throws: HostNotchPanelError.capacityExceeded) {
            try state.validate(
                fixture.admission(
                    active: ["notchShelf": "1.0.0", "calendar": "1.0.0"],
                    layout: .init(tiles: [tile]), reserved: ["calendar": 8]))
        }
    }

    @Test func originalTileCustomizationAndHardwarePositionArePreserved() throws {
        let fixture = HostNotchStateFixture()
        let state = fixture.state()
        try state.validate(fixture.admission())
        let request = try #require(state.slots.first).request(presentationID: UUID())
        #expect(request.location == "notch")
        #expect(request.section == "music")
        #expect(request.surface?.tile == fixture.tile)
        #expect(request.surface?.target == .notch)
        #expect(
            state.panelFrame(display: fixture.display)
                == CGRect(x: 12, y: 38, width: 1000, height: 742))
        let decoded = try HostNotchPanelState.decode(JSONEncoder().encode(state))
        #expect(decoded == state)
    }

    @Test func originalCapacityRemainsStableAcrossCollapseAndExpandedHome() throws {
        let fixture = HostNotchStateFixture()
        let expanded = fixture.state()
        let collapsed = try fixture.mutate([
            "phase": "collapsed", "shapeWidth": 234, "shapeHeight": 28, "slots": [],
        ])
        try collapsed.validate(fixture.admission())
        #expect(
            collapsed.panelSize(display: fixture.display)
                == expanded.panelSize(display: fixture.display))
        #expect(
            collapsed.panelFrame(display: fixture.display)
                == expanded.panelFrame(display: fixture.display))
    }

    @Test func originalBrowserCapacityAndScreenMarginArePreserved() throws {
        let fixture = HostNotchStateFixture()
        let display = HostNotchDisplay(
            id: 1, frame: CGRect(x: -2560, y: 240, width: 2560, height: 1600),
            collapsedSize: CGSize(width: 150, height: 32))
        let admission = HostNotchPanelAdmission(
            ownershipID: fixture.ownershipID, notchVersion: "1.0.0",
            presentationID: fixture.presentationID, display: display, previousRevision: nil,
            activeVersions: ["notchShelf": "1.0.0"], layout: .init(tiles: []))
        let browser = try fixture.mutate([
            "activeTab": "browser", "shapeWidth": 1800, "shapeHeight": 1588,
            "capacityWidth": 2200, "capacityHeight": 1588, "acceptsKeyFocus": true, "slots": [],
        ])
        try browser.validate(admission)
        #expect(browser.panelSize(display: display) == CGSize(width: 2224, height: 1598))
        #expect(
            browser.panelFrame(display: display)
                == CGRect(x: -2392, y: 242, width: 2224, height: 1598))
        let collapsed = try fixture.mutate([
            "phase": "collapsed", "shapeWidth": 150, "shapeHeight": 32,
            "capacityWidth": 2200, "capacityHeight": 1588, "slots": [],
        ])
        try collapsed.validate(admission)
        #expect(collapsed.panelSize(display: display) == browser.panelSize(display: display))
        var nonfinite = browser
        nonfinite.capacityWidth = .nan
        #expect(throws: HostNotchPanelError.invalidState) { try nonfinite.validate(admission) }
        for fields in [
            ["capacityWidth": 2513], ["capacityHeight": 1589],
            ["capacityWidth": 100], ["capacityHeight": -1],
        ] {
            #expect(throws: HostNotchPanelError.invalidState) {
                try fixture.mutate(fields).validate(admission)
            }
        }
    }

    @Test func staleGenerationDisplayVersionAndRevisionAreRejected() throws {
        let fixture = HostNotchStateFixture()
        #expect(throws: HostNotchPanelError.staleState) {
            try fixture.state().validate(fixture.admission(previousRevision: 1))
        }
        for mutation in [
            ["ownershipID": UUID().uuidString], ["presentationID": UUID().uuidString],
            ["displayID": 99], ["version": "2.0.0"], ["contractVersion": 2],
        ] as [[String: Any]] {
            let state = try fixture.mutate(mutation)
            #expect(throws: HostNotchPanelError.staleState) {
                try state.validate(fixture.admission())
            }
        }
        #expect(throws: HostNotchPanelError.staleState) {
            try fixture.state().validate(fixture.admission(active: ["music": "1.0.0"]))
        }
    }

    @Test func foreignSavedTilesDisabledProvidersAndPrivacyAreRejected() throws {
        let fixture = HostNotchStateFixture()
        #expect(throws: HostNotchPanelError.unavailableProvider) {
            try fixture.state().validate(fixture.admission(active: ["notchShelf": "1.0.0"]))
        }
        #expect(throws: HostNotchPanelError.unavailableProvider) {
            try fixture.state().validate(fixture.admission(hidden: [.music]))
        }
        #expect(throws: HostNotchPanelError.invalidState) {
            try fixture.state().validate(fixture.admission(layout: .init(tiles: [])))
        }
        var changed = fixture.tile
        changed.itemLimit = 1
        #expect(throws: HostNotchPanelError.invalidState) {
            try fixture.state().validate(fixture.admission(layout: .init(tiles: [changed])))
        }
    }

    @Test func malformedFramesDuplicateSlotsAndUnboundedPayloadAreRejected() throws {
        let fixture = HostNotchStateFixture()
        for rectangle in [
            HostNotchRectangle(x: -1, y: 42, width: 280, height: 160),
            HostNotchRectangle(x: 222, y: 42, width: 900, height: 160),
            HostNotchRectangle(x: 12, y: 42, width: 280, height: 0),
            HostNotchRectangle(x: .nan, y: 42, width: 280, height: 160),
        ] {
            #expect(throws: HostNotchPanelError.invalidState) {
                try fixture.state(slots: [fixture.slot(rectangle: rectangle)]).validate(
                    fixture.admission())
            }
        }
        let slot = fixture.slot()
        #expect(throws: HostNotchPanelError.invalidState) {
            try fixture.state(slots: [slot, slot]).validate(fixture.admission())
        }
        #expect(throws: HostNotchPanelError.invalidState) {
            try fixture.state(slots: Array(repeating: slot, count: 33)).validate(
                fixture.admission())
        }
        #expect(throws: HostNotchPanelError.invalidState) {
            _ = try HostNotchPanelState.decode(Data(repeating: 32, count: 131_073))
        }
        for mutation in [
            ["shapeWidth": 1600], ["activeTab": "foreign"], ["visible": false],
            ["acceptsKeyFocus": true],
        ] as [[String: Any]] {
            #expect(throws: HostNotchPanelError.invalidState) {
                try fixture.mutate(mutation).validate(fixture.admission())
            }
        }
    }

    @Test func collapsedAndHeaderRegionsRemainOwnedMusicRoutes() throws {
        let fixture = HostNotchStateFixture()
        let leading = fixture.slot(kind: .collapsedLeading)
        let trailing = fixture.slot(kind: .collapsedTrailing)
        try fixture.state(phase: .collapsed, slots: [leading, trailing]).validate(
            fixture.admission())
        #expect(try leading.request(presentationID: UUID()).section == "music.glance.leading")
        #expect(try trailing.request(presentationID: UUID()).section == "music.glance.trailing")
        #expect(throws: HostNotchPanelError.invalidState) {
            try fixture.state(phase: .collapsed).validate(fixture.admission())
        }
        let header = fixture.slot(kind: .header)
        try fixture.state(slots: [header]).validate(fixture.admission())
        #expect(try header.request(presentationID: UUID()).section == "music.header")
    }

    @Test func sceneCapacityIncludesOtherWindowsWithoutDroppingAnyCard() throws {
        let fixture = HostNotchStateFixture()
        try fixture.state().validate(fixture.admission(reserved: ["music": 15]))
        #expect(throws: HostNotchPanelError.capacityExceeded) {
            try fixture.state().validate(fixture.admission(reserved: ["music": 16]))
        }
        #expect(throws: HostNotchPanelError.invalidState) {
            try fixture.state().validate(fixture.admission(reserved: ["music": -1]))
        }
        #expect(fixture.state().slots.count == 1)
    }

    @Test func providerTabsCannotSupplyAnUnrelatedProviderOrMainPage() throws {
        let fixture = HostNotchStateFixture()
        let slot = fixture.slot(
            provider: "clipboard", tile: .init(.ability("clipboard")), kind: .providerTab)
        try fixture.state(tab: "clipboard", slots: [slot]).validate(
            fixture.admission(active: ["notchShelf": "1.0.0", "clipboard": "1.0.0"]))
        #expect(try slot.request(presentationID: UUID()).section == "clipboard")
        #expect(throws: HostNotchPanelError.invalidState) {
            try fixture.state(tab: "audio", slots: [slot]).validate(
                fixture.admission(active: ["notchShelf": "1.0.0", "clipboard": "1.0.0"]))
        }
        #expect(fixture.slot(provider: "system", tile: .init(.ability("system"))).section == nil)
    }
}

struct HostNotchStateFixture {
    let ownershipID = UUID()
    let presentationID = UUID()
    let display = HostNotchDisplay(
        id: 1, frame: CGRect(x: 0, y: 0, width: 1024, height: 780),
        collapsedSize: CGSize(width: 150, height: 28))
    var tile: SurfaceTile {
        var tile = SurfaceTile(.music)
        tile.title = "Synthetic customized player"
        tile.sourceIDs = ["synthetic-source"]
        tile.hiddenFields = ["volume"]
        tile.itemLimit = 4
        return tile
    }
    func slot(
        provider: String = "music", tile: SurfaceTile? = nil,
        kind: HostNotchNativeSlot.Kind = .card, rectangle: HostNotchRectangle? = nil
    ) -> HostNotchNativeSlot {
        HostNotchNativeSlot(
            id: UUID(), providerID: provider, providerVersion: "1.0.0", kind: kind,
            tile: tile ?? self.tile,
            rectangle: rectangle ?? .init(x: 222, y: 68, width: 280, height: 160))
    }
    func state(
        phase: HostNotchPanelState.Phase = .expanded, tab: String = "home",
        slots: [HostNotchNativeSlot]? = nil
    ) -> HostNotchPanelState {
        HostNotchPanelState(
            contractVersion: 1, ownershipID: ownershipID, version: "1.0.0", revision: 1,
            displayID: 1, presentationID: presentationID, phase: phase, activeTab: tab,
            shapeWidth: 580, shapeHeight: 400, visible: true, acceptsPointer: true,
            acceptsKeyFocus: false, slots: slots ?? [slot()])
    }
    func admission(
        previousRevision: UInt64? = nil, active: [String: String]? = nil,
        layout: SurfaceLayout? = nil, hidden: Set<SurfaceWidget> = [], reserved: [String: Int] = [:]
    ) -> HostNotchPanelAdmission {
        HostNotchPanelAdmission(
            ownershipID: ownershipID, notchVersion: "1.0.0", presentationID: presentationID,
            display: display, previousRevision: previousRevision,
            activeVersions: active ?? ["notchShelf": "1.0.0", "music": "1.0.0"],
            layout: layout ?? .init(tiles: [tile]), hiddenWidgets: hidden,
            reservedProviderScenes: reserved)
    }
    func mutate(_ fields: [String: Any]) throws -> HostNotchPanelState {
        var document = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(state())) as? [String: Any])
        fields.forEach { document[$0.key] = $0.value }
        return try HostNotchPanelState.decode(JSONSerialization.data(withJSONObject: document))
    }
}
