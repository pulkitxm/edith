import AppKit
import EdithExtensionSupport
import Foundation

@MainActor final class NotchPanelEngine {
    static let maximumBytes = 131_072
    private(set) var identity: NotchPanelIdentity?
    private(set) var displays: [UInt32: NotchPanelDisplay] = [:]
    private(set) var revision: UInt64 = 1
    private var version = ""
    private var slots: [UInt32: [NotchPanelSlot]] = [:]
    private var heights: [UUID: Double] = [:]
    private var failures: [UUID: String] = [:]
    private var pointers: [UInt32: NotchPanelPointer] = [:]
    private var waiter: (UUID, CheckedContinuation<NotchPanelBatch, Error>)?
    private var waitTimer: Task<Void, Never>?
    private var stopped = false
    weak var controller: NotchShelfController?
    private let context: SurfaceHostContext
    private let connectedDisplays: () -> [UInt32: CGSize]
    private let invalidate: (UUID) -> Void

    init(
        context: SurfaceHostContext, connectedDisplays: @escaping () -> [UInt32: CGSize],
        invalidate: @escaping (UUID) -> Void = { _ in }
    ) {
        self.context = context
        self.connectedDisplays = connectedDisplays
        self.invalidate = invalidate
    }

    var attached: Bool { identity != nil && !stopped }

    func attach(_ request: NotchPanelAttach) throws -> NotchPanelBatch {
        guard !stopped, identity == nil, controller == nil,
            context.activeVersions["notchShelf"] == request.version,
            !request.displays.isEmpty, request.displays.count <= 4,
            Set(request.displays.map(\.displayID)).count == request.displays.count,
            Set(request.displays.map(\.presentationID)).count == request.displays.count,
            request.displays.filter(\.isBuiltin).count <= 1
        else { throw ExtensionPeerError.rejected("Notch panel ownership cannot attach.") }
        let connected = connectedDisplays()
        for display in request.displays {
            guard display.valid, let size = connected[display.displayID],
                abs(size.width - display.width) < 1, abs(size.height - display.height) < 1
            else { throw ExtensionPeerError.invalidRequest }
        }
        identity = .init(ownershipID: request.ownershipID, generation: UUID())
        version = request.version
        displays = Dictionary(uniqueKeysWithValues: request.displays.map { ($0.displayID, $0) })
        return try batch()
    }

    func bind(_ controller: NotchShelfController) {
        self.controller = controller
        controller.panelEngine = self
        controller.onPanelStateChanged = { [weak self] in self?.changed() }
        controller.configureHostDisplays(Array(displays.values))
        changed()
    }

    func changed() {
        guard attached, revision < UInt64.max else { return }
        revision += 1
        pruneSlots()
        if let waiter {
            self.waiter = nil
            waitTimer?.cancel(); waitTimer = nil
            do { waiter.1.resume(returning: try batch()) } catch {
                waiter.1.resume(throwing: error)
            }
        }
        for display in displays.values { invalidate(display.presentationID) }
    }

    func wait(_ request: NotchPanelWait) async throws -> NotchPanelBatch {
        try validate(request.identity)
        guard request.timeout.isFinite, (0.01...25).contains(request.timeout),
            request.revision <= revision, waiter == nil
        else { throw ExtensionPeerError.invalidRequest }
        if request.revision < revision { return try batch() }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()); return }
                waiter = (id, continuation)
                waitTimer = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(request.timeout)) } catch { return }
                    guard let self, let waiter, waiter.0 == id else { return }
                    self.waiter = nil; waitTimer = nil
                    do { waiter.1.resume(returning: try batch()) } catch {
                        waiter.1.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelWait(id) }
        }
    }

    private func cancelWait(_ id: UUID) {
        guard let waiter, waiter.0 == id else { return }
        self.waiter = nil
        waitTimer?.cancel(); waitTimer = nil
        waiter.1.resume(throwing: CancellationError())
    }

    func geometry(_ request: NotchPanelGeometry) throws {
        try validate(
            request.identity, display: request.displayID, presentation: request.presentationID)
        guard let controller, request.revision <= revision,
            request.layout == controller.surfaceLayout, request.slots.count <= 32,
            Set(request.slots.map(\.id)).count == request.slots.count
        else { throw ExtensionPeerError.invalidRequest }
        let state = try state(for: request.displayID)
        var counts: [String: Int] = [:]
        var cards = Set<String>()
        var kinds = Set<NotchPanelSlot.Kind>()
        for slot in request.slots {
            guard slot.id != request.presentationID, slot.rectangle.valid,
                state.bounds.contains(slot.rectangle.frame), admissible(slot, state: state),
                slot.kind != .card || cards.insert(slot.tile.id).inserted,
                slot.kind == .card || kinds.insert(slot.kind).inserted
            else { throw ExtensionPeerError.invalidRequest }
            counts[slot.providerID, default: 0] += 1
            guard counts[slot.providerID, default: 0] <= 16 else {
                throw ExtensionPeerError.rejected(
                    "The provider has reached its native scene capacity.")
            }
            _ = try SurfaceSnapshotRequest(target: .notch, tile: slot.tile).encoded(
                providerID: slot.providerID)
        }
        guard slots[request.displayID] != request.slots else { return }
        slots[request.displayID] = request.slots
        changed()
    }

    func measure(_ request: NotchPanelMeasure) throws {
        try validate(
            request.identity, display: request.displayID, presentation: request.presentationID)
        guard request.revision <= revision, request.height.isFinite,
            (1...1200).contains(request.height),
            let slot = slots[request.displayID]?.first(where: { $0.id == request.slotID }),
            admissible(slot, state: try state(for: request.displayID)),
            request.error.map({ $0.utf8.count <= 512 && !$0.utf8.contains(0) }) ?? true
        else { throw ExtensionPeerError.invalidRequest }
        guard
            (heights[slot.id].map({ abs($0 - request.height) >= 1 }) ?? true)
                || failures[slot.id] != request.error
        else { return }
        heights[slot.id] = request.height
        failures[slot.id] = request.error
        changed()
    }

    func pointer(_ request: NotchPanelPointer) throws {
        try validate(
            request.identity, display: request.displayID, presentation: request.presentationID)
        guard let display = displays[request.displayID], request.x.isFinite, request.y.isFinite,
            (-128...display.width + 128).contains(request.x),
            (-128...display.height + 128).contains(request.y), request.buttons <= 31
        else { throw ExtensionPeerError.invalidRequest }
        pointers[request.displayID] = request
        controller?.hostPointer(request, display: display)
    }

    func detach(_ expected: NotchPanelIdentity) throws {
        try validate(expected)
        stop()
    }

    func stop() {
        stopped = true
        if let waiter { cancelWait(waiter.0) }
        slots = [:]; heights = [:]; failures = [:]; pointers = [:]
        controller?.onPanelStateChanged = nil
        for display in displays.values { invalidate(display.presentationID) }
    }

    func batch() throws -> NotchPanelBatch {
        guard let identity, attached else { throw ExtensionPeerError.unavailable }
        let result = NotchPanelBatch(
            identity: identity, revision: revision,
            states: try displays.keys.sorted().map { try state(for: $0) })
        guard try JSONEncoder().encode(result).count <= Self.maximumBytes else {
            throw ExtensionPeerError.rejected("The Notch panel state exceeds its capacity.")
        }
        return result
    }

    func chrome(_ request: NotchChromeRead) throws -> NotchChromeSnapshot {
        guard let identity, let display = displays[request.displayID], let controller else {
            throw ExtensionPeerError.unavailable
        }
        try validate(identity, display: request.displayID, presentation: request.presentationID)
        let result = NotchChromeSnapshot(
            identity: identity, revision: revision, display: display,
            panel: try state(for: display.displayID),
            layout: controller.surfaceLayout, activeVersions: context.activeVersions,
            hiddenWidgets: Set(
                controller.surfaceLayout.tiles.map(\.widget).filter { controller.privacy.hides($0) }
            ),
            items: Array(controller.items.prefix(512)), selectedIDs: controller.selectedIDs,
            livePositions: controller.livePositions, layoutEditing: controller.layoutEditing,
            visibleTabs: controller.visibleTabs.map(\.rawValue),
            hovering: controller.isHovering(on: display.displayID),
            leadingGlance: controller.leadingGlance, trailingGlance: controller.trailingGlance,
            glanceWingWidth: controller.glanceWingWidth, alert: controller.currentAlert,
            shelfOperationError: controller.shelfOperationError, heights: heights,
            failures: failures)
        guard controller.items.count <= 512,
            try JSONEncoder().encode(result).count <= Self.maximumBytes
        else {
            throw ExtensionPeerError.rejected("The Notch chrome state exceeds its capacity.")
        }
        return result
    }

    func action(_ request: NotchChromeAction) throws {
        try validate(
            request.identity, display: request.displayID, presentation: request.presentationID)
        guard let controller, request.revision <= revision else {
            throw ExtensionPeerError.unavailable
        }
        let item = request.itemID.flatMap { id in controller.items.first { $0.id == id } }
        switch request.operation {
        case .tab:
            guard let raw = request.tab, let tab = NotchTab(rawValue: raw),
                controller.visibleTabs.contains(tab)
            else { throw ExtensionPeerError.invalidRequest }
            controller.selectTab(tab)
        case .collapse: controller.collapseNow()
        case .editing:
            guard let flag = request.flag else { throw ExtensionPeerError.invalidRequest }
            controller.layoutEditing = flag
        case .layout:
            guard let layout = request.layout, layout == layout.normalized(),
                request.revision == revision,
                layout.encoded.utf8.count <= Self.maximumBytes
            else { throw ExtensionPeerError.invalidRequest }
            controller.layouts.update(.notch) { $0 = layout }
            controller.synchronize()
        case .undo: controller.layouts.undo(.notch); controller.synchronize()
        case .redo: controller.layouts.redo(.notch); controller.synchronize()
        case .customize: controller.openCustomization(tileID: request.tileID)
        case .select, .open, .reveal, .remove, .move:
            guard let item else { throw ExtensionPeerError.invalidRequest }
            switch request.operation {
            case .select: controller.toggleSelection(item)
            case .open: controller.open(item)
            case .reveal: controller.reveal(item)
            case .remove: controller.remove(item)
            case .move:
                guard let x = request.x, let y = request.y, let width = request.width,
                    let height = request.height,
                    [x, y, width, height].allSatisfy(\.isFinite), (1...1200).contains(width),
                    (1...1024).contains(height),
                    (-1200...2400).contains(x), (-1024...2048).contains(y)
                else { throw ExtensionPeerError.invalidRequest }
                controller.canvasDrag(
                    item, to: CGPoint(x: x, y: y), in: CGSize(width: width, height: height))
            default: break
            }
        case .endMove: controller.endCanvasDrag()
        case .dismissFailure: controller.dismissShelfFailure()
        case .alertTap:
            guard let alert = controller.currentAlert else { throw ExtensionPeerError.unavailable }
            controller.alertTapped(alert)
        case .alertHover:
            guard let flag = request.flag else { throw ExtensionPeerError.invalidRequest }
            controller.alertHover(flag)
        case .homeHeight:
            guard let height = request.height, height.isFinite, (1...1024).contains(height) else {
                throw ExtensionPeerError.invalidRequest
            }
            controller.measureHomeContent(height)
        }
        changed()
    }

    private func validate(
        _ expected: NotchPanelIdentity, display: UInt32? = nil, presentation: UUID? = nil
    ) throws {
        guard attached, identity == expected, context.activeVersions["notchShelf"] == version,
            display == nil || displays[display!]?.presentationID == presentation
        else {
            throw ExtensionPeerError.rejected("The Notch panel ownership is stale.")
        }
    }

    private func state(for id: UInt32) throws -> NotchPanelState {
        guard let identity, let display = displays[id] else { throw ExtensionPeerError.unavailable }
        let expanded = controller?.isExpanded(on: id) == true
        let alert = display.isBuiltin && !expanded && controller?.currentAlert != nil
        let phase: NotchPanelState.Phase = expanded ? .expanded : alert ? .alert : .collapsed
        let size = controller?.hostShapeSize(display) ?? display.collapsedSize
        let visible = controller?.hostPanelVisible(display) ?? true
        let pointer = pointers[id]
        let localShape = CGRect(
            x: (display.width - size.width) / 2, y: 0, width: size.width, height: size.height)
        let accepts =
            visible
            && (expanded
                ? NotchGeometry.expandedAcceptsPointer(
                    CGPoint(x: pointer?.x ?? -9999, y: pointer?.y ?? -9999), shapeFrame: localShape,
                    buttonPressed: (pointer?.buttons ?? 0) != 0,
                    heldOpen: controller?.hostHeldOpen == true)
                : alert
                    && localShape.contains(CGPoint(x: pointer?.x ?? -9999, y: pointer?.y ?? -9999)))
        var result = NotchPanelState(
            contractVersion: 1, ownershipID: identity.ownershipID, version: version,
            revision: revision,
            displayID: id, presentationID: display.presentationID, phase: phase,
            activeTab: controller?.activeTab.rawValue ?? "home",
            shapeWidth: min(max(1, size.width), min(1200, display.width - 48)),
            shapeHeight: min(max(1, size.height), min(1024, display.height - 48)),
            visible: visible, acceptsPointer: accepts,
            acceptsKeyFocus: expanded && controller?.activeTab == .browser, slots: [])
        result.slots =
            visible
            ? (slots[id] ?? []).filter {
                admissible($0, state: result) && result.bounds.contains($0.rectangle.frame)
            } : []
        return result
    }

    private func admissible(_ slot: NotchPanelSlot, state: NotchPanelState) -> Bool {
        guard let controller, state.visible, slot.section != nil, !slot.tile.hidden,
            slot.tile.widget.providerIDs == [slot.providerID],
            context.activeVersions[slot.providerID] == slot.providerVersion,
            !controller.privacy.hides(slot.tile.widget)
        else { return false }
        switch slot.kind {
        case .card:
            return state.phase == .expanded && state.activeTab == "home"
                && controller.visibleSurfaceLayout.visible.contains(slot.tile)
        case .providerTab:
            let expected = ["herdr": "agents", "clipboard": "clipboard", "audioMixer": "audio"][
                slot.providerID]
            return state.phase == .expanded && state.activeTab == expected
        case .collapsedLeading:
            return state.phase == .collapsed && controller.leadingGlance?.source == .music
                && controller.musicGlancesEnabled
        case .collapsedTrailing:
            return state.phase == .collapsed && controller.trailingGlance?.source == .music
                && controller.musicGlancesEnabled
        case .header: return state.phase == .expanded && controller.musicGlancesEnabled
        }
    }

    private func pruneSlots() {
        for id in displays.keys {
            guard let state = try? state(for: id) else { slots[id] = []; continue }
            slots[id] = state.slots
        }
        let active = Set(slots.values.flatMap { $0.map(\.id) })
        heights = heights.filter { active.contains($0.key) }
        failures = failures.filter { active.contains($0.key) }
    }
}
