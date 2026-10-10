import AppKit
import EdithExtensionSupport
import Foundation
import Observation

@MainActor @Observable final class NotchChromeClient: NotchChromeFacade {
    typealias Invoke = @MainActor (String, Data) async throws -> Data
    private(set) var snapshot: NotchChromeSnapshot?
    private(set) var error: String?
    private(set) var stopped = false
    let displayID: UInt32
    let presentationID: UUID
    let remoteLayouts = NotchRemoteLayoutStore()
    private let invoke: Invoke
    private var generation = UUID()
    private var observer: NSObjectProtocol?
    private var refreshTask: Task<Void, Never>?
    private var actionTask: Task<Void, Never>?
    private var geometryTask: Task<Void, Never>?
    private var readAgain = false
    private var actionCount = 0
    private var lastHomeHeight: Double?
    private var slotsByKey: [String: UUID] = [:]
    private var reported: [NotchPanelSlot] = []
    private(set) var camera: NotchCameraClient?
    private let namespace: String
    private(set) var browser: NotchBrowserStore?
    private var browserDrains: [UUID: Task<Void, Never>] = [:]
    private var teardown: Task<Void, Never>?
    private var remoteBrowser: NotchBrowserRemoteClient?
    private var thumbnailTasks: [UUID: Task<NSImage?, Never>] = [:]

    init(displayID: UInt32, presentationID: UUID, namespace: String, invoke: @escaping Invoke) {
        self.namespace = namespace
        self.displayID = displayID
        self.presentationID = presentationID
        self.invoke = invoke
        remoteLayouts.changed = { [weak self] layout in
            self?.perform(.layout) { $0.layout = layout }
        }
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(namespace + ".notchPanel." + presentationID.uuidString),
            object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.invalidate() } }
    }

    func invalidate() {
        guard !stopped else { return }
        if refreshTask != nil { readAgain = true; return }
        let token = generation
        refreshTask = Task { [weak self] in
            guard let self else { return }
            defer { if generation == token { refreshTask = nil } }
            repeat {
                readAgain = false
                do {
                    let data = try await invoke(
                        "notch.chrome.read",
                        JSONEncoder().encode(
                            NotchChromeRead(displayID: displayID, presentationID: presentationID)))
                    try apply(data, generation: token)
                } catch {
                    if !stopped, generation == token, !Task.isCancelled {
                        self.error = error.localizedDescription
                    }
                }
            } while readAgain && !Task.isCancelled && !stopped
        }
    }

    func refresh() async {
        invalidate()
        await refreshTask?.value
    }

    func stop() {
        guard !stopped else { return }
        let refreshing = refreshTask
        let acting = actionTask
        let geometry = geometryTask
        let thumbnails = Array(thumbnailTasks.values)
        stopped = true
        generation = UUID()
        refreshTask?.cancel(); refreshTask = nil
        actionTask?.cancel(); actionTask = nil
        geometryTask?.cancel(); geometryTask = nil
        for task in thumbnailTasks.values { task.cancel() }
        thumbnailTasks = [:]
        if let observer { DistributedNotificationCenter.default().removeObserver(observer) }
        observer = nil
        snapshot = nil; reported = []; slotsByKey = [:]
        remoteLayouts.changed = nil
        camera?.stop(); camera = nil
        drainBrowser()
        let drains = Array(browserDrains.values)
        teardown = Task {
            await refreshing?.value; await acting?.value; await geometry?.value
            for task in thumbnails { _ = await task.value }
            for task in drains { await task.value }
        }
    }

    func stopAndWait() async { stop(); await teardown?.value }

    private func drainBrowser() {
        guard let browser else { return }
        browser.shutdown()
        let id = UUID()
        browserDrains[id] = Task {
            await browser.shutdownAndWait()
            browserDrains[id] = nil
        }
        self.browser = nil; remoteBrowser = nil
    }

    private func apply(_ data: Data, generation token: UUID) throws {
        try Task.checkCancellation()
        guard !stopped, generation == token, data.count <= NotchPanelEngine.maximumBytes else {
            return
        }
        let next = try JSONDecoder().decode(NotchChromeSnapshot.self, from: data)
        guard next.display.displayID == displayID, next.display.presentationID == presentationID,
            next.display.valid, next.panel.displayID == displayID,
            next.panel.presentationID == presentationID,
            next.panel.ownershipID == next.identity.ownershipID,
            next.panel.revision == next.revision,
            next.panel.contractVersion == 1,
            next.activeVersions["notchShelf"] == next.panel.version,
            next.panel.shapeWidth.isFinite, next.panel.shapeHeight.isFinite,
            (1...(next.panel.activeTab == "browser"
                ? next.display.width - 48 : min(1200, next.display.width - 48))).contains(
                    next.panel.shapeWidth),
            (1...(next.panel.activeTab == "browser"
                ? next.display.height - 12 : min(1024, next.display.height - 48))).contains(
                    next.panel.shapeHeight),
            next.panel.capacityWidth.map({
                $0.isFinite && $0 >= next.panel.shapeWidth && $0 <= next.display.width - 48
            }) ?? true,
            next.panel.capacityHeight.map({
                $0.isFinite && $0 >= next.panel.shapeHeight && $0 <= next.display.height - 12
            }) ?? true,
            next.items.count <= 512, Set(next.items.map(\.id)).count == next.items.count,
            next.panel.slots.count <= 32,
            Set(next.panel.slots.map(\.id)).count == next.panel.slots.count,
            next.layout == next.layout.normalized(),
            next.visibleTabs.allSatisfy({ NotchTab(rawValue: $0) != nil }),
            next.heights.count <= 128,
            next.heights.values.allSatisfy({ $0.isFinite && (1...1200).contains($0) }),
            next.failures.count <= 128, next.failures.values.allSatisfy({ $0.utf8.count <= 512 })
        else { throw ExtensionPeerError.invalidRequest }
        if let snapshot {
            guard next.identity == snapshot.identity, next.revision >= snapshot.revision else {
                throw ExtensionPeerError.invalidRequest
            }
        }
        snapshot = next
        remoteLayouts.apply(next.layout)
        NotchPresenterState.shared.remoteValues = next.privacyValues
        if camera == nil {
            camera = NotchCameraClient(namespace: namespace, presentationID: presentationID) {
                [weak self] operation, deviceID in
                guard let self, !stopped, let snapshot else { throw ExtensionPeerError.unavailable }
                let request = NotchCameraRequest(
                    identity: snapshot.identity, displayID: displayID,
                    presentationID: presentationID, operation: operation, deviceID: deviceID)
                return try await invoke("notch.chrome.camera", JSONEncoder().encode(request))
            }
        }
        if let state = next.browserState {
            if let remoteBrowser {
                remoteBrowser.apply(state)
            } else {
                let remote = NotchBrowserRemoteClient(
                    state: state,
                    request: { [weak self] operation in
                        guard let self, let snapshot, !stopped else { return nil }
                        return NotchBrowserRemoteRequest(
                            identity: snapshot.identity, displayID: displayID,
                            presentationID: presentationID, operation: operation)
                    },
                    invoke: { [invoke] request in
                        return try await invoke(
                            "notch.chrome.browser", JSONEncoder().encode(request))
                    })
                remoteBrowser = remote
                browser = NotchBrowserStore(remote: remote)
                browser?.screenSize = { [weak self] in
                    guard let display = self?.snapshot?.display else { return nil }
                    return NotchBrowserGeometry.available(
                        screen: CGSize(width: display.width, height: display.height),
                        notchHeight: display.collapsedHeight)
                }
            }
        } else {
            drainBrowser()
        }
        error = nil
    }

    func perform(
        _ operation: NotchChromeAction.Operation,
        configure: (inout NotchChromeAction) -> Void = { _ in }
    ) {
        guard !stopped, let snapshot, actionCount < 32 else { return }
        var request = NotchChromeAction(
            identity: snapshot.identity, displayID: displayID, presentationID: presentationID,
            revision: snapshot.revision, operation: operation)
        configure(&request)
        let token = generation
        let previous = actionTask
        actionCount += 1
        actionTask = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            defer { actionCount -= 1 }
            guard !stopped, generation == token, !Task.isCancelled, let snapshot = self.snapshot
            else { return }
            request = NotchChromeAction(
                identity: snapshot.identity, displayID: request.displayID,
                presentationID: request.presentationID, revision: snapshot.revision,
                operation: request.operation, itemID: request.itemID, tab: request.tab,
                flag: request.flag, x: request.x, y: request.y, width: request.width,
                height: request.height, tileID: request.tileID, layout: request.layout)
            do {
                let data = try await invoke("notch.chrome.action", JSONEncoder().encode(request))
                try apply(data, generation: token)
            } catch {
                if !stopped, generation == token, !Task.isCancelled {
                    self.error = error.localizedDescription; invalidate()
                }
            }
        }
    }

    func drainActions() async { await actionTask?.value }

    func supportsNative(tile: SurfaceTile, kind: NotchPanelSlot.Kind) -> Bool {
        guard tile.widget.providerIDs.count == 1, let provider = tile.widget.providerIDs.first
        else { return false }
        return NotchPanelSlot(
            id: UUID(), providerID: provider, providerVersion: "", kind: kind, tile: tile,
            rectangle: .init(x: 0, y: 0, width: 1, height: 1)
        ).section != nil
    }

    func quickActions(
        tile: SurfaceTile, providerID: String? = nil, actionID: String? = nil,
        session: NotchLidAwakeSession? = nil
    ) async throws -> NotchQuickActionState {
        guard !stopped, let snapshot else { throw ExtensionPeerError.unavailable }
        let token = generation
        let request = NotchQuickActionRequest(
            identity: snapshot.identity, displayID: displayID, presentationID: presentationID,
            tile: tile, providerID: providerID, actionID: actionID, session: session)
        let data = try await invoke("notch.chrome.quick", JSONEncoder().encode(request))
        try Task.checkCancellation()
        guard !stopped, generation == token, data.count <= NotchPanelEngine.maximumBytes else {
            throw CancellationError()
        }
        return try JSONDecoder().decode(NotchQuickActionState.self, from: data)
    }

    func slot(tile: SurfaceTile, kind: NotchPanelSlot.Kind, rectangle: CGRect) -> NotchPanelSlot? {
        guard let snapshot, snapshot.panel.visible, !hides(tile.widget),
            tile.widget.providerIDs.count == 1, let provider = tile.widget.providerIDs.first,
            let version = snapshot.activeVersions[provider]
        else { return nil }
        let key = kind.rawValue + ":" + provider + ":" + tile.id
        let id = slotsByKey[key] ?? UUID()
        slotsByKey[key] = id
        let clipped = rectangle.intersection(snapshot.panel.bounds)
        guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else { return nil }
        let slot = NotchPanelSlot(
            id: id, providerID: provider, providerVersion: version, kind: kind, tile: tile,
            rectangle: .init(
                x: clipped.minX, y: clipped.minY, width: clipped.width, height: clipped.height))
        return slot.section == nil ? nil : slot
    }

    func report(_ slots: [NotchPanelSlot]) {
        guard !stopped, let snapshot, slots.count <= 32 else { return }
        let sorted = slots.sorted { $0.id.uuidString < $1.id.uuidString }
        guard sorted != reported else { return }
        reported = sorted
        geometryTask?.cancel()
        let token = generation
        geometryTask = Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await invoke(
                    "notch.panel.geometry",
                    JSONEncoder().encode(
                        NotchPanelGeometry(
                            identity: snapshot.identity, displayID: displayID,
                            presentationID: presentationID, revision: snapshot.revision,
                            layout: snapshot.layout, slots: sorted)))
            } catch {
                if !stopped, generation == token, !Task.isCancelled {
                    self.error = error.localizedDescription
                }
            }
        }
    }

    func slotHeight(tile: SurfaceTile, kind: NotchPanelSlot.Kind) -> Double? {
        guard let provider = tile.widget.providerIDs.first,
            let id = slotsByKey[kind.rawValue + ":" + provider + ":" + tile.id]
        else { return nil }
        return snapshot?.heights[id]
    }

    func slotFailure(tile: SurfaceTile, kind: NotchPanelSlot.Kind) -> String? {
        guard let provider = tile.widget.providerIDs.first,
            let id = slotsByKey[kind.rawValue + ":" + provider + ":" + tile.id]
        else { return nil }
        return snapshot?.failures[id]
    }

    var activeTab: NotchTab { NotchTab(rawValue: snapshot?.panel.activeTab ?? "home") ?? .home }
    var layoutEditing: Bool {
        get { snapshot?.layoutEditing ?? false }
        set { perform(.editing) { $0.flag = newValue } }
    }
    var items: [ShelfItem] { snapshot?.items ?? [] }
    var selectedIDs: Set<UUID> { snapshot?.selectedIDs ?? [] }
    var livePositions: [UUID: CGPoint] { snapshot?.livePositions ?? [:] }
    var shelfOperationError: String? { snapshot?.shelfOperationError ?? error }
    var currentAlert: NotchAlert? { snapshot?.alert }
    var leadingGlance: NotchSurfaceGlance? { snapshot?.leadingGlance }
    var trailingGlance: NotchSurfaceGlance? { snapshot?.trailingGlance }
    var glanceWingWidth: CGFloat { CGFloat(snapshot?.glanceWingWidth ?? 0) }
    var surfaceLayout: SurfaceLayout { remoteLayouts.notch }
    var visibleSurfaceLayout: SurfaceLayout {
        var layout = surfaceLayout
        layout.tiles = layout.visible.filter { $0.widget.available(activeIDs: activeIDs) }
        return layout
    }
    var visibleTabs: [NotchTab] { snapshot?.visibleTabs.compactMap(NotchTab.init(rawValue:)) ?? [] }
    var activeIDs: Set<String> { Set(snapshot?.activeVersions.keys.map { $0 } ?? []) }
    var chromeLayouts: any NotchChromeLayoutStore { remoteLayouts }
    var surfaceClient: SurfaceSnapshotClient? { nil }
    var usesNativeSlots: Bool { true }
    var isExpanded: Bool { snapshot?.panel.phase == .expanded }
    func hides(_ widget: SurfaceWidget) -> Bool { snapshot?.hiddenWidgets.contains(widget) ?? true }
    func isExpanded(on id: UInt32) -> Bool { id == displayID && isExpanded }
    func isHovering(on id: UInt32) -> Bool { id == displayID && snapshot?.hovering == true }
    func expandedSize(on id: UInt32) -> CGSize {
        CGSize(width: snapshot?.panel.shapeWidth ?? 580, height: snapshot?.panel.shapeHeight ?? 412)
    }
    func measureHomeContent(_ height: Double) {
        guard height.isFinite, lastHomeHeight.map({ abs($0 - height) >= 1 }) ?? true else { return }
        lastHomeHeight = height
        perform(.homeHeight) { $0.height = height }
    }
    func openCustomization(tileID: String?) { perform(.customize) { $0.tileID = tileID } }
    func selectTab(_ tab: NotchTab) { perform(.tab) { $0.tab = tab.rawValue } }
    func collapseNow() { perform(.collapse) }
    func openGlance(_ glance: NotchSurfaceGlance, on id: UInt32) {
        perform(.glance) { $0.tab = glance.tab.rawValue }
    }
    func hoverChanged(_ hovering: Bool, on id: UInt32?) {}
    func alertHover(_ hovering: Bool) { perform(.alertHover) { $0.flag = hovering } }
    func alertTapped(_ alert: NotchAlert) { perform(.alertTap) }
    func toggleSelection(_ item: ShelfItem) { perform(.select) { $0.itemID = item.id } }
    func open(_ item: ShelfItem) { perform(.open) { $0.itemID = item.id } }
    func reveal(_ item: ShelfItem) { perform(.reveal) { $0.itemID = item.id } }
    func share(_ item: ShelfItem) { perform(.share) { $0.itemID = item.id } }
    func remove(_ item: ShelfItem) { perform(.remove) { $0.itemID = item.id } }
    func dismissShelfFailure() { perform(.dismissFailure) }
    func canvasDrag(_ item: ShelfItem, to point: CGPoint, in size: CGSize) {
        perform(.move) {
            $0.itemID = item.id; $0.x = point.x; $0.y = point.y; $0.width = size.width;
            $0.height = size.height
        }
    }
    func endCanvasDrag() { perform(.endMove) }
    func beginExternalDrag(of item: ShelfItem) { perform(.drag) { $0.itemID = item.id } }
    func thumbnail(for item: ShelfItem) async -> NSImage? {
        guard !stopped, !hides(.ability("notchShelf")), let snapshot else { return nil }
        if let task = thumbnailTasks[item.id] { return await task.value }
        let token = generation
        let task = Task { [weak self] () -> NSImage? in
            guard let self else { return nil }
            do {
                let request = NotchChromeAction(
                    identity: snapshot.identity, displayID: displayID,
                    presentationID: presentationID, revision: snapshot.revision, operation: .select,
                    itemID: item.id)
                let data = try await invoke("notch.chrome.thumbnail", JSONEncoder().encode(request))
                guard !Task.isCancelled, !stopped, generation == token, data.count <= 524288 else {
                    return nil
                }
                return NSImage(data: data)
            } catch { return nil }
        }
        thumbnailTasks[item.id] = task
        let result = await task.value
        thumbnailTasks[item.id] = nil
        return result
    }
}
