import CoreGraphics
import EdithExtensionSupport
import Foundation

struct NotchPanelRectangle: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var frame: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    var valid: Bool { [x, y, width, height].allSatisfy(\.isFinite) && width > 0 && height > 0 }
}

struct NotchPanelDisplay: Codable, Equatable, Sendable {
    let displayID: UInt32
    let presentationID: UUID
    let width: Double
    let height: Double
    let collapsedWidth: Double
    let collapsedHeight: Double
    let isBuiltin: Bool
    var collapsedSize: CGSize { CGSize(width: collapsedWidth, height: collapsedHeight) }
    var valid: Bool {
        [width, height, collapsedWidth, collapsedHeight].allSatisfy(\.isFinite)
            && (49...16384).contains(width) && (49...16384).contains(height)
            && (1...min(1200, width - 48)).contains(collapsedWidth)
            && (1...128).contains(collapsedHeight)
    }
}

struct NotchPanelSlot: Codable, Equatable, Sendable, Identifiable {
    enum Kind: String, Codable, Sendable {
        case card, providerTab, collapsedLeading, collapsedTrailing, header
    }
    let id: UUID
    let providerID: String
    let providerVersion: String
    let kind: Kind
    let tile: SurfaceTile
    let rectangle: NotchPanelRectangle
    static func supportsSharedCard(_ widget: SurfaceWidget) -> Bool {
        switch widget {
        case .codeStats, .databases, .machines, .github, .desk, .media, .ability: true
        default: false
        }
    }

    static func anchorProvider(
        tile: SurfaceTile, kind: Kind, activeVersions: [String: String]
    ) -> String? {
        if kind == .card, supportsSharedCard(tile.widget) {
            return tile.widget.providerIDs.sorted().first { activeVersions[$0] != nil }
        }
        guard tile.widget.providerIDs.count == 1, let provider = tile.widget.providerIDs.first,
            activeVersions[provider] != nil
        else { return nil }
        return provider
    }

    var section: String? {
        if kind == .card, Self.supportsSharedCard(tile.widget) { return "surface.card" }
        return switch (kind, providerID, tile.widget) {
        case (.card, "music", .music): "music"
        case (.card, "calendar", .calendar): "calendar"
        case (.card, "usage", .usage): "usage"
        case (.card, "usage", .activity): "activity"
        case (.card, "usage", .limits): "limits"
        case (.providerTab, "herdr", .agents): "agents"
        case (.providerTab, "clipboard", .ability("clipboard")): "clipboard"
        case (.providerTab, "audioMixer", .ability("audioMixer")): "audioMixer"
        case (.collapsedLeading, "music", .music): "music.glance.leading"
        case (.collapsedTrailing, "music", .music): "music.glance.trailing"
        case (.header, "music", .music): "music.header"
        default: nil
        }
    }
}

struct NotchPanelState: Codable, Equatable, Sendable {
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
    var slots: [NotchPanelSlot]
    var capacityWidth: Double? = nil
    var capacityHeight: Double? = nil
    var layoutEditing: Bool? = nil
    var bounds: CGRect {
        CGRect(
            x: 0, y: 0, width: max(shapeWidth, capacityWidth ?? 0) + 24,
            height: max(shapeHeight, capacityHeight ?? 0) + 10)
    }
}

struct NotchPanelAttach: Codable, Sendable {
    let ownershipID: UUID
    let version: String
    let displays: [NotchPanelDisplay]
}

struct NotchPanelIdentity: Codable, Equatable, Sendable {
    let ownershipID: UUID
    let generation: UUID
}

struct NotchPanelBatch: Codable, Sendable {
    let identity: NotchPanelIdentity
    let revision: UInt64
    let states: [NotchPanelState]
    let transfers: [NotchPanelTransfer]
}

struct NotchPanelWait: Codable, Sendable {
    let identity: NotchPanelIdentity
    let revision: UInt64
    let timeout: Double
}

struct NotchPanelGeometry: Codable, Sendable {
    let identity: NotchPanelIdentity
    let displayID: UInt32
    let presentationID: UUID
    let revision: UInt64
    let layout: SurfaceLayout
    let slots: [NotchPanelSlot]
}

struct NotchPanelMeasure: Codable, Sendable {
    let identity: NotchPanelIdentity
    let displayID: UInt32
    let presentationID: UUID
    let slotID: UUID
    let revision: UInt64
    let height: Double
    let error: String?
}

struct NotchPanelPointer: Codable, Sendable {
    let identity: NotchPanelIdentity
    let displayID: UInt32
    let presentationID: UUID
    let x: Double
    let y: Double
    let buttons: UInt32
    let option: Bool
    let draggingFiles: Bool
}

struct NotchChromeRead: Codable, Sendable {
    let displayID: UInt32
    let presentationID: UUID
}

struct NotchChromeSnapshot: Codable, Sendable {
    let identity: NotchPanelIdentity
    let revision: UInt64
    let display: NotchPanelDisplay
    let panel: NotchPanelState
    let layout: SurfaceLayout
    let activeVersions: [String: String]
    let hiddenWidgets: Set<SurfaceWidget>
    let items: [ShelfItem]
    let selectedIDs: Set<UUID>
    let livePositions: [UUID: CGPoint]
    let layoutEditing: Bool
    let visibleTabs: [String]
    let hovering: Bool
    let leadingGlance: NotchSurfaceGlance?
    let trailingGlance: NotchSurfaceGlance?
    let glanceWingWidth: Double
    let alert: NotchAlert?
    let shelfOperationError: String?
    let heights: [UUID: Double]
    let failures: [UUID: String]
    let browserState: NotchBrowserClientState?
    let privacyValues: [String: String]
}

struct NotchChromeAction: Codable, Sendable {
    enum Operation: String, Codable, Sendable {
        case tab, glance, collapse, editing, layout, undo, redo, customize, select, open, reveal,
            remove
        case alertHover, alertTap, dismissFailure, move, endMove, homeHeight, share, drag
    }
    let identity: NotchPanelIdentity
    let displayID: UInt32
    let presentationID: UUID
    let revision: UInt64
    let operation: Operation
    var itemID: UUID? = nil
    var tab: String? = nil
    var flag: Bool? = nil
    var x: Double? = nil
    var y: Double? = nil
    var width: Double? = nil
    var height: Double? = nil
    var tileID: String? = nil
    var layout: SurfaceLayout? = nil
}

struct NotchPanelTransfer: Codable, Sendable, Identifiable {
    enum Kind: String, Codable, Sendable { case share, drag }
    let id: UUID
    let displayID: UInt32
    let presentationID: UUID
    let kind: Kind
    let items: [ShelfItem]
    let fileURLs: [URL]
    var cancelled = false
}

struct NotchPanelTransferFinish: Codable, Equatable, Sendable {
    let identity: NotchPanelIdentity
    let id: UUID
    let completed: Bool
    let outside: Bool
    let error: String?
}

struct NotchPanelDrop: Codable, Sendable {
    let identity: NotchPanelIdentity
    let displayID: UInt32
    let presentationID: UUID
    let fileURLs: [URL]
    let text: String?
    let x: Double?
    let y: Double?
}

struct NotchPanelPromise: Codable, Equatable, Sendable {
    let identity: NotchPanelIdentity
    let displayID: UInt32
    let presentationID: UUID
    let id: UUID
    let fileURL: URL?
    let x: Double?
    let y: Double?
}

struct NotchPanelTransferAcknowledgement: Codable, Sendable {
    let identity: NotchPanelIdentity
    let id: UUID
    let opened: Bool
    let error: String?
}

struct NotchPanelSceneStop: Codable, Sendable {
    let identity: NotchPanelIdentity
    let displayID: UInt32
    let presentationID: UUID
}
