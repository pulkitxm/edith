import CoreGraphics
import EdithExtensionSupport
import EdithHostCore
import Foundation

enum HostNotchPanelError: Error, Equatable {
    case invalidState, staleState, unavailableProvider, capacityExceeded
}

struct HostNotchRectangle: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    var frame: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    var valid: Bool {
        [x, y, width, height].allSatisfy(\.isFinite) && width > 0 && height > 0
    }
}

struct HostNotchDisplay: Equatable, Sendable {
    let id: UInt32
    let frame: CGRect
    let collapsedSize: CGSize

    var valid: Bool {
        [
            frame.minX, frame.minY, frame.width, frame.height, collapsedSize.width,
            collapsedSize.height,
        ].allSatisfy(\.isFinite)
            && frame.width > 48 && frame.height > 48
            && collapsedSize.width > 0 && collapsedSize.width <= frame.width
            && collapsedSize.height > 0 && collapsedSize.height <= 128
    }
}

struct HostNotchNativeSlot: Codable, Equatable, Sendable, Identifiable {
    enum Kind: String, Codable, Sendable {
        case card, providerTab, collapsedLeading, collapsedTrailing, header
    }

    let id: UUID
    let providerID: String
    let providerVersion: String
    let kind: Kind
    let tile: SurfaceTile
    let rectangle: HostNotchRectangle

    var section: String? {
        switch (kind, providerID, tile.widget) {
        case (.card, "music", .music), (.providerTab, "music", .music): return "music"
        case (.card, "calendar", .calendar): return "calendar"
        case (.card, "usage", .usage): return "usage"
        case (.card, "usage", .activity): return "activity"
        case (.card, "usage", .limits): return "limits"
        case (.providerTab, "herdr", .agents): return "agents"
        case (.providerTab, "clipboard", .ability("clipboard")): return "clipboard"
        case (.providerTab, "audioMixer", .ability("audioMixer")): return "audioMixer"
        case (.collapsedLeading, "music", .music): return "music.glance.leading"
        case (.collapsedTrailing, "music", .music): return "music.glance.trailing"
        case (.header, "music", .music): return "music.header"
        default: return nil
        }
    }

    func request(presentationID: UUID) throws -> HostExtensionContentRequest {
        guard let section else { throw HostNotchPanelError.invalidState }
        return HostExtensionContentRequest(
            extensionID: providerID, location: "notch", section: section,
            presentationID: presentationID,
            surface: SurfaceSnapshotRequest(target: .notch, tile: tile))
    }
}

struct HostNotchPanelState: Codable, Equatable, Sendable {
    enum Phase: String, Codable, Sendable { case collapsed, expanded, alert }

    let contractVersion: Int
    let ownershipID: UUID
    let version: String
    let revision: UInt64
    let displayID: UInt32
    let presentationID: UUID
    let phase: Phase
    let activeTab: String
    let shapeWidth: Double
    let shapeHeight: Double
    let visible: Bool
    let acceptsPointer: Bool
    let acceptsKeyFocus: Bool
    let slots: [HostNotchNativeSlot]

    static let maximumBytes = 131_072
    static let maximumSlots = 32
    static let providerSceneLimit = 16

    static func decode(_ data: Data) throws -> Self {
        guard !data.isEmpty, data.count <= maximumBytes else {
            throw HostNotchPanelError.invalidState
        }
        return try JSONDecoder().decode(Self.self, from: data)
    }

    func validate(_ admission: HostNotchPanelAdmission) throws {
        guard contractVersion == 1, admission.display.valid,
            displayID == admission.display.id,
            presentationID == admission.presentationID,
            ownershipID == admission.ownershipID, version == admission.notchVersion,
            admission.activeVersions["notchShelf"] == version,
            revision > (admission.previousRevision ?? 0)
        else { throw HostNotchPanelError.staleState }
        let panelBounds = CGRect(x: 0, y: 0, width: panelSize.width, height: panelSize.height)
        guard
            ["home", "agents", "browser", "files", "clipboard", "audio", "camera"].contains(
                activeTab),
            shapeWidth.isFinite, shapeHeight.isFinite,
            (1...min(1200, admission.display.frame.width - 48)).contains(shapeWidth),
            (1...min(1024, admission.display.frame.height - 48)).contains(shapeHeight),
            slots.count <= Self.maximumSlots, Set(slots.map(\.id)).count == slots.count,
            !acceptsKeyFocus || (phase == .expanded && activeTab == "browser"),
            visible || slots.isEmpty
        else { throw HostNotchPanelError.invalidState }
        var cards = Set<String>()
        var kinds = Set<String>()
        var providerCounts = admission.reservedProviderScenes
        for slot in slots {
            guard slot.rectangle.valid, panelBounds.contains(slot.rectangle.frame),
                slot.section != nil, !slot.tile.hidden,
                slot.tile.widget.providerIDs == [slot.providerID]
            else { throw HostNotchPanelError.invalidState }
            guard admission.activeVersions[slot.providerID] == slot.providerVersion,
                !admission.hiddenWidgets.contains(slot.tile.widget)
            else { throw HostNotchPanelError.unavailableProvider }
            _ = try SurfaceSnapshotRequest(target: .notch, tile: slot.tile).encoded(
                providerID: slot.providerID)
            switch slot.kind {
            case .card:
                guard phase == .expanded, activeTab == "home",
                    admission.layout.visible.contains(slot.tile),
                    cards.insert(slot.tile.id).inserted
                else { throw HostNotchPanelError.invalidState }
            case .providerTab:
                let expected: String? =
                    switch slot.providerID {
                    case "herdr": "agents"
                    case "clipboard": "clipboard"
                    case "audioMixer": "audio"
                    default: nil
                    }
                guard phase == .expanded, activeTab == expected,
                    kinds.insert(slot.kind.rawValue).inserted
                else { throw HostNotchPanelError.invalidState }
            case .collapsedLeading, .collapsedTrailing:
                guard phase == .collapsed, kinds.insert(slot.kind.rawValue).inserted else {
                    throw HostNotchPanelError.invalidState
                }
            case .header:
                guard phase == .expanded, kinds.insert(slot.kind.rawValue).inserted else {
                    throw HostNotchPanelError.invalidState
                }
            }
            providerCounts[slot.providerID, default: 0] += 1
            guard providerCounts[slot.providerID, default: 0] <= Self.providerSceneLimit else {
                throw HostNotchPanelError.capacityExceeded
            }
        }
    }

    var panelSize: CGSize { CGSize(width: shapeWidth + 24, height: shapeHeight + 10) }
    func panelFrame(display: HostNotchDisplay) -> CGRect {
        CGRect(
            x: display.frame.midX - panelSize.width / 2,
            y: display.frame.maxY - panelSize.height,
            width: panelSize.width, height: panelSize.height)
    }
}

struct HostNotchPanelAdmission {
    let ownershipID: UUID
    let notchVersion: String
    let presentationID: UUID
    let display: HostNotchDisplay
    let previousRevision: UInt64?
    let activeVersions: [String: String]
    let layout: SurfaceLayout
    var hiddenWidgets: Set<SurfaceWidget> = []
    var reservedProviderScenes: [String: Int] = [:]
}
