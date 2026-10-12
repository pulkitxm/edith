import AppKit
import EdithExtensionSupport
import Foundation
import SwiftUI

@MainActor protocol NotchChromeLayoutStore: AnyObject {
    var notch: SurfaceLayout { get }
    @discardableResult func update(_ target: SurfaceTarget, _ edit: (inout SurfaceLayout) -> Void)
        -> Bool
    func undo(_ target: SurfaceTarget)
    func redo(_ target: SurfaceTarget)
    func canUndo(_ target: SurfaceTarget) -> Bool
    func canRedo(_ target: SurfaceTarget) -> Bool
    func reload()
}

extension SurfaceLayoutStore: NotchChromeLayoutStore {}

@MainActor protocol NotchChromeFacade: AnyObject {
    var activeTab: NotchTab { get }
    var layoutEditing: Bool { get set }
    var items: [ShelfItem] { get }
    var selectedIDs: Set<UUID> { get }
    var livePositions: [UUID: CGPoint] { get }
    var shelfOperationError: String? { get }
    var currentAlert: NotchAlert? { get }
    var leadingGlance: NotchSurfaceGlance? { get }
    var trailingGlance: NotchSurfaceGlance? { get }
    var glanceWingWidth: CGFloat { get }
    var surfaceLayout: SurfaceLayout { get }
    var visibleSurfaceLayout: SurfaceLayout { get }
    var visibleTabs: [NotchTab] { get }
    var activeIDs: Set<String> { get }
    var chromeLayouts: any NotchChromeLayoutStore { get }
    var surfaceClient: SurfaceSnapshotClient? { get }
    var browser: NotchBrowserStore? { get }
    var usesNativeSlots: Bool { get }
    var isExpanded: Bool { get }
    func hides(_ widget: SurfaceWidget) -> Bool
    func isExpanded(on id: UInt32) -> Bool
    func isHovering(on id: UInt32) -> Bool
    func expandedSize(on id: UInt32) -> CGSize
    func measureHomeContent(_ height: Double)
    func openCustomization(tileID: String?)
    func selectTab(_ tab: NotchTab)
    func collapseNow()
    func openGlance(_ glance: NotchSurfaceGlance, on id: UInt32)
    func hoverChanged(_ hovering: Bool, on id: UInt32?)
    func alertHover(_ hovering: Bool)
    func alertTapped(_ alert: NotchAlert)
    func toggleSelection(_ item: ShelfItem)
    func open(_ item: ShelfItem)
    func reveal(_ item: ShelfItem)
    func share(_ item: ShelfItem)
    func remove(_ item: ShelfItem)
    func dismissShelfFailure()
    func thumbnail(for item: ShelfItem) async -> NSImage?
    func canvasDrag(_ item: ShelfItem, to point: CGPoint, in size: CGSize)
    func endCanvasDrag()
    func beginExternalDrag(of item: ShelfItem)
}

extension NotchChromeFacade {
    func openCustomization() { openCustomization(tileID: nil) }
}

extension NotchShelfController: NotchChromeFacade {
    var chromeLayouts: any NotchChromeLayoutStore { layouts }
    var surfaceClient: SurfaceSnapshotClient? { requests }
    var usesNativeSlots: Bool { false }
    func hides(_ widget: SurfaceWidget) -> Bool { privacy.hides(widget) }
}

@MainActor @Observable final class NotchRemoteLayoutStore: NotchChromeLayoutStore {
    private(set) var notch = SurfaceLayout.decode(nil, target: .notch)
    private var undoHistory: [SurfaceLayout] = []
    private var redoHistory: [SurfaceLayout] = []
    var changed: ((SurfaceLayout) -> Void)?
    func apply(_ layout: SurfaceLayout) { notch = layout }
    @discardableResult func update(_ target: SurfaceTarget, _ edit: (inout SurfaceLayout) -> Void)
        -> Bool
    {
        guard target == .notch else { return false }
        var next = notch
        edit(&next)
        next = next.normalized()
        guard next.encoded.utf8.count <= NotchPanelEngine.maximumBytes else { return false }
        guard next != notch else { return true }
        undoHistory = Array((undoHistory + [notch]).suffix(50))
        redoHistory = []
        notch = next
        changed?(next)
        return true
    }
    func undo(_ target: SurfaceTarget) {
        guard target == .notch, let previous = undoHistory.popLast() else { return }
        redoHistory.append(notch); notch = previous; changed?(notch)
    }
    func redo(_ target: SurfaceTarget) {
        guard target == .notch, let next = redoHistory.popLast() else { return }
        undoHistory.append(notch); notch = next; changed?(notch)
    }
    func canUndo(_ target: SurfaceTarget) -> Bool { target == .notch && !undoHistory.isEmpty }
    func canRedo(_ target: SurfaceTarget) -> Bool { target == .notch && !redoHistory.isEmpty }
    func reload() {}
}
