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
    private var transfer: (NotchPanelTransfer, ShelfStagedFiles)?
    private var shareAcknowledgement: (UUID, CheckedContinuation<Void, Error>)?
    private var transferTimer: Task<Void, Never>?
    private var promises: Set<UUID> = []
    private var pointers: [UInt32: NotchPanelPointer] = [:]
    private var waiter: (UUID, CheckedContinuation<NotchPanelBatch, Error>)?
    private var waitTimer: Task<Void, Never>?
    private var stopped = false
    weak var controller: NotchShelfController?
    private let context: SurfaceHostContext
    private let connectedDisplays: () -> [UInt32: CGSize]
    private let invalidate: (UUID) -> Void
    private let cameraFactory: @MainActor () -> NotchCameraEngine
    private(set) var cameraEngine: NotchCameraEngine?
    private var cameraPresentation: UUID?

    init(
        context: SurfaceHostContext, connectedDisplays: @escaping () -> [UInt32: CGSize],
        invalidate: @escaping (UUID) -> Void = { _ in },
        cameraFactory: @escaping @MainActor () -> NotchCameraEngine = {
            NotchCameraEngine(hardware: NativeNotchCameraHardware())
        }
    ) {
        self.cameraFactory = cameraFactory
        self.context = context
        self.connectedDisplays = connectedDisplays
        self.invalidate = invalidate
    }

    var attached: Bool { identity != nil && !stopped }

    func attach(_ request: NotchPanelAttach) throws -> NotchPanelBatch {
        if let identity, !stopped {
            guard identity.ownershipID == request.ownershipID, version == request.version,
                request.displays.count == displays.count,
                request.displays.allSatisfy({ displays[$0.displayID] == $0 })
            else { throw ExtensionPeerError.rejected("Notch panel ownership cannot attach.") }
            return try batch()
        }
        guard !stopped, identity == nil, controller == nil,
            context.activeVersions["notchShelf"] == request.version,
            !request.displays.isEmpty, request.displays.count <= 8,
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
        if !displays.keys.contains(where: { cameraAllowed(on: $0) }) {
            cameraEngine?.stopCapture()
        }
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
        for (id, existing) in slots where id != request.displayID {
            guard let state = try? self.state(for: id) else { continue }
            for slot in existing where admissible(slot, state: state) {
                counts[slot.providerID, default: 0] += 1
            }
        }
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
        let previous = try state(for: request.displayID)
        let previousHover = controller?.isHovering(on: request.displayID)
        let previousRevision = revision
        pointers[request.displayID] = request
        controller?.hostPointer(request, display: display)
        if revision == previousRevision,
            previous != (try state(for: request.displayID))
                || previousHover != controller?.isHovering(on: request.displayID)
        {
            changed()
        }
    }

    func detach(_ expected: NotchPanelIdentity) throws {
        guard identity == expected else { throw ExtensionPeerError.invalidRequest }
        if stopped { return }
        stop()
    }

    func stop() {
        stopped = true
        cameraEngine?.shutdown()
        if let waiter { cancelWait(waiter.0) }
        slots = [:]; heights = [:]; failures = [:]; pointers = [:]
        transferTimer?.cancel(); transferTimer = nil
        transfer = nil
        shareAcknowledgement?.1.resume(throwing: CancellationError()); shareAcknowledgement = nil
        controller?.store.cancelActionSelection()
        for id in promises { controller?.store.discardPromiseDestination(id: id) }
        promises = []
        controller?.onPanelStateChanged = nil
        for display in displays.values { invalidate(display.presentationID) }
    }

    func batch() throws -> NotchPanelBatch {
        guard let identity, attached else { throw ExtensionPeerError.unavailable }
        let result = NotchPanelBatch(
            identity: identity, revision: revision,
            states: try displays.keys.sorted().map { try state(for: $0) },
            transfers: transfer.map { [$0.0] } ?? [])
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
            failures: failures,
            browserState: try controller.browserEngine?.state(includeAvatars: false),
            privacyValues: controller.privacy.values)
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
        case .tab, .glance:
            guard let raw = request.tab, let tab = NotchTab(rawValue: raw),
                controller.visibleTabs.contains(tab)
            else { throw ExtensionPeerError.invalidRequest }
            if request.operation == .glance {
                controller.expand(on: request.displayID, preferredTab: tab)
            } else {
                controller.selectTab(tab)
            }
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
        case .share, .drag:
            guard let item, !controller.privacy.hides(.ability("notchShelf")) else {
                throw ExtensionPeerError.invalidRequest
            }
            try beginTransfer(
                kind: request.operation == .share ? .share : .drag, item: item, request: request)
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

    private func beginTransfer(
        kind: NotchPanelTransfer.Kind, item: ShelfItem, request: NotchChromeAction
    ) throws {
        guard transfer == nil, let controller else { throw ShelfActionSelectionError.busy }
        let ids = controller.selectedIDs.contains(item.id) ? controller.selectedIDs : [item.id]
        let selection = try controller.store.actionSelection(itemIDs: ids)
        let staged = try selection.stagedFiles()
        let descriptor = NotchPanelTransfer(
            id: UUID(), displayID: request.displayID, presentationID: request.presentationID,
            kind: kind, items: selection.items, fileURLs: staged.urls)
        guard descriptor.items.count <= 512, try JSONEncoder().encode(descriptor).count <= 32768,
            controller.store.retainActionSelection(selection.snapshot)
        else { throw ShelfActionSelectionError.busy }
        transfer = (descriptor, staged)
        transferTimer = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(60)) } catch { return }
            guard let self, transfer?.0.id == descriptor.id else { return }
            cancelTransfer(descriptor.id, error: "The native file action timed out.")
        }
    }

    func shareCLI(_ ids: [UUID]) async throws {
        guard !ids.isEmpty, let controller,
            let display = displays[
                controller.expandedDisplay ?? displays.values.first(where: \.isBuiltin)?.displayID
                    ?? displays.keys.sorted().first ?? 0],
            let identity, let item = controller.items.first(where: { $0.id == ids[0] }),
            Set(ids).count == ids.count,
            ids.allSatisfy({ id in controller.items.contains { $0.id == id } })
        else { throw ExtensionPeerError.unavailable }
        let selected = controller.selectedIDs
        controller.hostSelect(Set(ids))
        defer { controller.hostSelect(selected) }
        let request = NotchChromeAction(
            identity: identity, displayID: display.displayID,
            presentationID: display.presentationID, revision: revision, operation: .share,
            itemID: item.id)
        try beginTransfer(kind: .share, item: item, request: request)
        guard let id = transfer?.0.id else { throw ExtensionPeerError.unavailable }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError()); cancelTransfer(id); return
                }
                shareAcknowledgement = (id, continuation)
                changed()
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelTransfer(id) }
        }
    }

    func acknowledgeTransfer(_ request: NotchPanelTransferAcknowledgement) throws {
        try validate(request.identity)
        guard transfer?.0.id == request.id, request.error.map({ $0.utf8.count <= 512 }) ?? true
        else { throw ExtensionPeerError.invalidRequest }
        if let acknowledgement = shareAcknowledgement, acknowledgement.0 == request.id {
            shareAcknowledgement = nil
            if request.opened {
                acknowledgement.1.resume()
            } else {
                acknowledgement.1.resume(
                    throwing: ExtensionPeerError.rejected(
                        request.error ?? "The native share picker could not open."))
            }
        }
        if !request.opened {
            try finishTransfer(
                .init(
                    identity: request.identity, id: request.id, completed: false, outside: false,
                    error: request.error))
        }
    }

    private func cancelTransfer(_ id: UUID, error: String? = nil) {
        guard transfer?.0.id == id else { return }
        transfer?.0.cancelled = true
        if let acknowledgement = shareAcknowledgement, acknowledgement.0 == id {
            shareAcknowledgement = nil
            if let error {
                acknowledgement.1.resume(throwing: ExtensionPeerError.rejected(error))
            } else {
                acknowledgement.1.resume(throwing: CancellationError())
            }
        }
        changed()
    }

    func finishTransfer(_ request: NotchPanelTransferFinish) throws {
        try validateOwnership(request.identity)
        guard let transfer, transfer.0.id == request.id, let controller,
            request.error.map({ $0.utf8.count <= 512 && !$0.utf8.contains(0) }) ?? true
        else { throw ExtensionPeerError.invalidRequest }
        self.transfer = nil
        if let acknowledgement = shareAcknowledgement, acknowledgement.0 == request.id {
            shareAcknowledgement = nil
            acknowledgement.1.resume(
                throwing: ExtensionPeerError.rejected(
                    request.error ?? "The native share picker closed before opening."))
        }
        transferTimer?.cancel(); transferTimer = nil
        controller.store.releaseActionSelection()
        if let error = request.error { controller.hostShelfFailure(error) }
        if transfer.0.kind == .drag, request.completed, request.outside,
            controller.context.defaults.object(forKey: AppStorageKeys.Notch.shelfRemoveAfterDragOut)
                as? Bool ?? true
        {
            let ids = Set(transfer.0.items.map(\.id))
            controller.hostRemoveAfterDrag(ids)
        }
        changed()
    }

    func drop(_ request: NotchPanelDrop) throws {
        try validate(
            request.identity, display: request.displayID, presentation: request.presentationID)
        guard let controller, request.fileURLs.count <= 32,
            request.fileURLs.allSatisfy({
                $0.isFileURL && $0.path.utf8.count <= 4096 && !$0.path.utf8.contains(0)
            }),
            request.text.map({ !$0.isEmpty && $0.utf8.count <= 65536 }) ?? true,
            !request.fileURLs.isEmpty || request.text != nil
        else { throw ExtensionPeerError.invalidRequest }
        let point = try dropPoint(x: request.x, y: request.y)
        controller.hostDrop(fileURLs: request.fileURLs, text: request.text, location: point)
        changed()
    }

    func preparePromise(_ request: NotchPanelPromise) throws -> URL {
        try validate(
            request.identity, display: request.displayID, presentation: request.presentationID)
        guard promises.count < 32, !promises.contains(request.id), request.fileURL == nil,
            let destination = controller?.store.promiseDestination(id: request.id)
        else { throw ExtensionPeerError.invalidRequest }
        _ = try dropPoint(x: request.x, y: request.y)
        promises.insert(request.id)
        return destination
    }

    func finishPromise(_ request: NotchPanelPromise) throws {
        try validateOwnership(
            request.identity, display: request.displayID, presentation: request.presentationID)
        guard promises.contains(request.id), let controller else {
            throw ExtensionPeerError.invalidRequest
        }
        let point = try dropPoint(x: request.x, y: request.y)
        if let url = request.fileURL, context.activeVersions["notchShelf"] == version {
            guard url.isFileURL, url.path.utf8.count <= 4096 else {
                throw ExtensionPeerError.invalidRequest
            }
            promises.remove(request.id)
            controller.store.adoptWhenAvailable(fileAt: url, id: request.id) {
                [weak controller] item in
                if let item, let point { controller?.store.setPosition(point, for: item) }
                controller?.synchronizeShelfItems()
            }
        } else {
            promises.remove(request.id)
            controller.store.discardPromiseDestination(id: request.id)
        }
        changed()
    }

    private func dropPoint(x: Double?, y: Double?) throws -> CGPoint? {
        guard x != nil || y != nil else { return nil }
        guard let x, let y, x.isFinite, y.isFinite, (-1200...2400).contains(x),
            (-1024...2048).contains(y)
        else { throw ExtensionPeerError.invalidRequest }
        return CGPoint(x: x, y: y)
    }

    func camera(_ request: NotchCameraRequest) async throws -> Data {
        if request.operation == .stop {
            try validateOwnership(
                request.identity, display: request.displayID, presentation: request.presentationID)
            if cameraPresentation == request.presentationID { cameraEngine?.stopCapture() }
            return Data("{}".utf8)
        }
        try validate(
            request.identity, display: request.displayID, presentation: request.presentationID)
        guard cameraAllowed(on: request.displayID) else {
            cameraEngine?.stopCapture(); throw ExtensionPeerError.unavailable
        }
        if cameraEngine == nil { cameraEngine = cameraFactory() }
        guard let cameraEngine else { throw ExtensionPeerError.unavailable }
        cameraPresentation = request.presentationID
        let namespace = context.sharedState.namespace
        cameraEngine.changed = {
            DistributedNotificationCenter.default().postNotificationName(
                Notification.Name(namespace + ".notchCamera." + request.presentationID.uuidString),
                object: nil, userInfo: nil, deliverImmediately: true)
        }
        let data = try await cameraEngine.execute(request)
        guard cameraAllowed(on: request.displayID) else {
            cameraEngine.stopCapture(); throw ExtensionPeerError.unavailable
        }
        try validate(
            request.identity, display: request.displayID, presentation: request.presentationID)
        return data
    }

    private func cameraAllowed(on displayID: UInt32) -> Bool {
        let privacy = controller?.privacy.values ?? [:]
        return context.activeVersions["notchShelf"] == version
            && controller?.activeTab == .camera
            && controller?.isExpanded(on: displayID) == true
            && (try? state(for: displayID).visible) == true
            && (privacy["active"] != "1" || privacy["blurCamera"] == "0")
    }

    func stopScene(_ request: NotchPanelSceneStop) throws {
        try validateOwnership(
            request.identity, display: request.displayID, presentation: request.presentationID)
        if cameraPresentation == request.presentationID {
            cameraEngine?.stopCapture(); cameraPresentation = nil
        }
        controller?.browserEngine?.release(owner: request.presentationID)
    }

    func browser(_ request: NotchBrowserRemoteRequest) async throws -> Data {
        let cleanup = [.leaseEnd, .downloadCancel, .importEnd].contains(request.operation)
        if cleanup {
            try validateOwnership(
                request.identity, display: request.displayID, presentation: request.presentationID)
        } else {
            try validate(
                request.identity, display: request.displayID, presentation: request.presentationID)
        }
        guard let engine = controller?.browserEngine else { throw ExtensionPeerError.unavailable }
        let data = try await engine.execute(request)
        if !cleanup {
            do {
                try validate(
                    request.identity, display: request.displayID,
                    presentation: request.presentationID)
            } catch {
                engine.release(owner: request.presentationID)
                throw error
            }
        }
        return data
    }

    func validateChromeIdentity(
        _ identity: NotchPanelIdentity, displayID: UInt32, presentationID: UUID
    ) throws {
        try validate(identity, display: displayID, presentation: presentationID)
    }

    private func validateOwnership(
        _ expected: NotchPanelIdentity, display: UInt32? = nil, presentation: UUID? = nil
    ) throws {
        guard attached, identity == expected,
            display == nil || displays[display!]?.presentationID == presentation
        else { throw ExtensionPeerError.rejected("The Notch panel ownership is stale.") }
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
        let capacity =
            controller?.hostCapacity(display)
            ?? CGSize(
                width: min(1200, display.width - 48),
                height: min(display.collapsedHeight + 760, display.height - 48))
        let browser = controller?.activeTab == .browser
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
            shapeWidth: min(
                max(1, size.width), browser ? display.width - 48 : min(1200, display.width - 48)),
            shapeHeight: min(
                max(1, size.height), browser ? display.height - 12 : min(1024, display.height - 48)),
            visible: visible, acceptsPointer: accepts,
            acceptsKeyFocus: expanded && controller?.activeTab == .browser, slots: [],
            capacityWidth: min(display.width - 48, max(size.width, capacity.width)),
            capacityHeight: min(display.height - 12, max(size.height, capacity.height)))
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
            guard let state = try? self.state(for: id) else { slots[id] = []; continue }
            slots[id] = state.slots
        }
        let active = Set(slots.values.flatMap { $0.map(\.id) })
        heights = heights.filter { active.contains($0.key) }
        failures = failures.filter { active.contains($0.key) }
    }
}
