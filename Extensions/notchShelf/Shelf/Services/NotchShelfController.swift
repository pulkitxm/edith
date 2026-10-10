import AppKit
import Combine
import CoreBluetooth
import EdithExtensionCommands
import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

extension NSScreen {
    fileprivate var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}

struct ShelfOperationRequestOutcome {
    let operation: ShelfItemOperation
    let requestID: String?
    let error: String?
}

enum ShelfOperationRequestRouter {
    static func route(
        _ info: [AnyHashable: Any], isSharing: Bool,
        perform: (ShelfItemOperation, Set<UUID>) -> String?
    ) -> ShelfOperationRequestOutcome? {
        guard let request = ShelfItemOperationExecution.request(info) else { return nil }
        let error =
            isSharing
            ? ShelfActionSelectionError.busy.localizedDescription
            : perform(request.operation, request.itemIDs)
        return ShelfOperationRequestOutcome(
            operation: request.operation, requestID: request.requestID, error: error)
    }
}

@MainActor
@Observable
final class NotchShelfController {
    private(set) var items: [ShelfItem] = []
    private(set) var expandedDisplay: CGDirectDisplayID?
    private(set) var hoverDisplay: CGDirectDisplayID?
    var activeTab: NotchTab = .home
    var layoutEditing = false { didSet { updatePanelFrames() } }
    private var homeContentHeight: CGFloat?
    let context: SurfaceHostContext
    let layouts: SurfaceLayoutStore
    let requests: SurfaceSnapshotClient
    let privacy: SurfacePrivacyState
    let bluetoothPrivacyRequired: () -> Bool
    private var hostDisplaySizes: [UInt32: CGSize] = [:]
    private(set) var activeIDs: Set<String> = []
    private(set) var surfaceSnapshots: [String: SurfaceSnapshot] = [:]
    private var glanceTask: Task<Void, Never>?
    private var stopped = false
    private var startsServices = false
    private let hostOwned: Bool
    private var hostOption = false
    weak var panelEngine: NotchPanelEngine?
    var onPanelStateChanged: (() -> Void)?
    private var contextObserver: NSObjectProtocol?
    private(set) var currentAlert: NotchAlert?
    private(set) var browser: NotchBrowserStore?
    private(set) var browserEngine: NotchBrowserEngine?
    private var alertDetectors: NotchAlertDetectors?
    private var alertWorkItem: DispatchWorkItem?
    private var alertPinned = false
    private var pendingAlerts: [PendingNotchAlert] = []
    private(set) var livePositions: [UUID: CGPoint] = [:]
    private(set) var selectedIDs: Set<UUID> = []
    private(set) var shelfOperationError: String?

    let store: ShelfStore
    private var panels: [CGDirectDisplayID: NSPanel] = [:]
    private var collapsedSizes: [CGDirectDisplayID: CGSize] = [:]
    private var builtinDisplayID: CGDirectDisplayID?
    private var fullScreenDisplays: Set<CGDirectDisplayID> = []

    private var screenObserver: NSObjectProtocol?
    private var spaceObserver: NSObjectProtocol?
    private var shelfOperationObserver: NSObjectProtocol?
    private var surfaceSettingsObserver: NSObjectProtocol?
    private var dragMonitor: Any?
    private var moveMonitorGlobal: Any?
    private var moveMonitorLocal: Any?
    private var interactionRects: [CGDirectDisplayID: CGRect] = [:]
    private var pointerInsideInterest = false
    private var gateDisplay: CGDirectDisplayID?
    private var gate = NotchHoverGate(
        openDwell: NotchShelfController.openDwell, closeGrace: NotchHidePolicy.shelf.closeGrace)
    private var gateWorkItem: DispatchWorkItem?
    static let openDwell: TimeInterval = 0.1
    private var lastDragChangeCount = -1
    private var collapseWorkItem: DispatchWorkItem?
    private var hostDragRemoval: DispatchWorkItem?
    private var panelSettleWorkItem: DispatchWorkItem?
    private var pendingDragOutIDs: Set<UUID> = []
    private var internalDragItemIDs: Set<UUID> = []
    private var sharePickerDelegate: SharePickerDelegate?
    private var shareStagedFiles: ShelfStagedFiles?
    private var dragStagedFiles: ShelfStagedFiles?
    private var isSharing = false
    private var dragStartPositions: [UUID: CGPoint] = [:]
    private var dragPointerStart: CGPoint?

    init(
        context: SurfaceHostContext, startsServices: Bool = true, root: URL = ShelfIndex.root,
        hostDisplays: [NotchPanelDisplay]? = nil,
        bluetoothPrivacyRequired: @escaping () -> Bool = {
            CBManager.authorization == .denied || CBManager.authorization == .restricted
        }
    ) {
        hostOwned = hostDisplays != nil
        self.bluetoothPrivacyRequired = bluetoothPrivacyRequired
        self.context = context
        self.startsServices = startsServices
        layouts = SurfaceLayoutStore(defaults: context.defaults) {
            NotchWorkerIPC.post("settingsChanged")
        }
        requests = SurfaceSnapshotClient(context: context)
        privacy = SurfacePrivacyState(channel: context.sharedState)
        store = ShelfStore(root: root)
        items = store.items
        if let hostDisplays { configureHostDisplays(hostDisplays) }
        activeIDs = context.activeIDs
        guard startsServices else { return }
        store.onExternalChange = { [weak self] in
            guard let self else { return }
            self.items = self.store.items
            self.onPanelStateChanged?()
        }
        shelfOperationObserver = NotchWorkerIPC.observe(
            NotchWorkerIPC.Name.shelfOperation,
            info: { [weak self] info in
                self?.performShelfOperation(info)
            })
        purgeExpired()
        rebuildPanels()
        surfaceSettingsObserver = NotchWorkerIPC.observe(NotchWorkerIPC.Name.settingsChanged) {
            [weak self] in
            self?.layouts.reload()
            self?.synchronize()
            self?.homeContentHeight = nil
            self?.updatePanelFrames()
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.rebuildPanels() }
        }
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.updateFullScreenVisibility() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                Task { @MainActor in self?.updateFullScreenVisibility() }
            }
        }
        if !hostOwned {
            dragMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
            ) { [weak self] event in
                MainActor.assumeIsolated { self?.handleGlobalMouse(event) }
            }
            startMoveMonitor()
        }
        startAlertsIfEnabled()
        startSurfaceObservation()
    }

    var ownedPanelCount: Int { panels.count }
    func hostShelfFailure(_ error: String) { presentShelfFailure(error) }
    func hostRemoveAfterDrag(_ ids: Set<UUID>) {
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.stopped else { return }
            self.removeMembers(self.items.filter { ids.contains($0.id) })
            self.onPanelStateChanged?()
        }
        hostDragRemoval?.cancel()
        hostDragRemoval = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }
    func hostDrop(fileURLs: [URL], text: String?, location: CGPoint?) {
        for url in fileURLs {
            if let location, let existing = store.item(forFileURL: url) {
                store.setPosition(location, for: existing)
                items = store.items
            } else {
                addFile(at: url, location: location)
            }
        }
        if let text { addText(text, location: location) }
    }
    func synchronizeShelfItems() { items = store.items; onPanelStateChanged?() }
    var isRunning: Bool { !stopped }
    var startsPanelServices: Bool { startsServices }

    var surfaceLayout: SurfaceLayout { layouts.notch }
    var visibleSurfaceLayout: SurfaceLayout {
        var layout = surfaceLayout
        layout.tiles = layout.visible.filter { $0.widget.available(activeIDs: activeIDs) }
        return layout
    }
    var visibleTabs: [NotchTab] {
        SurfaceNotchTab.visible(
            layout: surfaceLayout, activeIDs: activeIDs,
            browserEnabled: browser != nil || browserEngine != nil)
    }

    func synchronize() {
        guard !stopped else { return }
        activeIDs = context.activeIDs
        requests.retain(activeVersions: context.activeVersions)
        privacy.refresh()
        layouts.reload()
        activeTab = NotchTab.validSelection(activeTab, visible: visibleTabs)
        surfaceSnapshots = surfaceSnapshots.filter {
            activeIDs.contains($0.key) && !privacy.hides(Self.glanceWidget($0.key))
                && ($0.key != "music" || musicGlancesEnabled)
        }
        let browserEnabled = context.defaults.bool(forKey: AppStorageKeys.Notch.browserEnabled)
        if browserEnabled, browser == nil, browserEngine == nil {
            if hostOwned {
                let engine = NotchBrowserEngine(defaults: context.defaults)
                engine.changed = { [weak self] in self?.syncFrames() }
                browserEngine = engine
            } else {
                attachBrowser(NotchBrowserStore(defaults: context.defaults))
            }
        }
        if !browserEnabled {
            if let browser { browser.shutdown(); attachBrowser(nil) }
            browserEngine?.stop(); browserEngine = nil
            if activeTab == .browser { activeTab = .home }
        }
        if startsServices { syncAlerts(); beginGlanceRefresh() }
        updatePanelFrames()
    }

    func recordSurfaceSnapshot(_ snapshot: SurfaceSnapshot) {
        guard activeIDs.contains(snapshot.providerID),
            snapshot.providerID != "music" || musicGlancesEnabled,
            !privacy.hides(Self.glanceWidget(snapshot.providerID))
        else { return }
        let previous = surfaceSnapshots[snapshot.providerID]
        surfaceSnapshots[snapshot.providerID] = snapshot
        let pending = Int(snapshot.metrics.first { $0.id == "permissions" }?.value ?? "") ?? 0
        let previousPending =
            Int(previous?.metrics.first { $0.id == "permissions" }?.value ?? "") ?? 0
        let requestIDs = Set(snapshot.rows.filter { $0.field == "approvals" }.map(\.id))
        let previousIDs = Set(previous?.rows.filter { $0.field == "approvals" }.map(\.id) ?? [])
        if snapshot.providerID == "herdr", surfaceLayout.notchExpandPermissions,
            pending > 0, pending > previousPending || !requestIDs.subtracting(previousIDs).isEmpty,
            !layoutEditing, visibleTabs.contains(.agents)
        {
            expand(
                on: expandedDisplay ?? builtinDisplayID ?? CGMainDisplayID(), preferredTab: .agents)
        }
        if snapshot.providerID == "herdr", surfaceLayout.notchPrioritizePermissions, !layoutEditing,
            let count = snapshot.metrics.first(where: { $0.id == "permissions" })?.value,
            let pending = Int(count), pending > 0, visibleTabs.contains(.agents)
        {
            if let display = expandedDisplay { expand(on: display, preferredTab: .agents) }
        }
    }

    func installContextObserver() {
        contextObserver = context.sharedState.observe { [weak self] owner in
            guard owner == "host" || owner == "presenter" else { return }
            MainActor.assumeIsolated { self?.synchronize() }
        }
    }

    func beginGlanceRefresh() {
        glanceTask?.cancel()
        glanceTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, !self.stopped else { return }
                let providers = self.glanceProviderIDs
                for id in providers.sorted() {
                    let widget = Self.glanceWidget(id)
                    guard !self.isExpanded, self.activeIDs.contains(id), !self.privacy.hides(widget)
                    else { continue }
                    var tile = SurfaceTile(widget)
                    tile.itemLimit = 1
                    if widget == .agents {
                        tile.hiddenFields = []
                        tile.sourceIDs = self.surfaceLayout.notchAgentSources
                        tile.includeSubagents = self.surfaceLayout.notchIncludeSubagents
                    }
                    do {
                        let snapshot = try await self.requests.snapshot(
                            providerID: id, target: .notch, tile: tile)
                        guard !Task.isCancelled, self.activeIDs.contains(id),
                            !self.privacy.hides(widget)
                        else { continue }
                        self.recordSurfaceSnapshot(snapshot)
                        self.updatePanelFrames()
                    } catch {
                        self.surfaceSnapshots.removeValue(forKey: id)
                    }
                }
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
                self.updatePanelFrames()
            }
        }
    }

    private var alertsEnabled: Bool { flag(AppStorageKeys.Notch.alertsEnabled, default: true) }

    private func startAlertsIfEnabled() {
        guard alertsEnabled, alertDetectors == nil else { return }
        let detectors = NotchAlertDetectors(defaults: context.defaults) { [weak self] alert in
            self?.postAlert(alert)
        }
        detectors.start()
        alertDetectors = detectors
    }

    func syncAlerts() {
        if alertsEnabled {
            startAlertsIfEnabled()
            alertDetectors?.syncBluetooth()
        } else if let detectors = alertDetectors {
            detectors.stop()
            alertDetectors = nil
            dismissAlert()
        }
    }

    func postAlert(_ alert: NotchAlert) {
        guard alertsEnabled else { return }
        if isExpanded {
            pendingAlerts = NotchAlertLogic.queue(pendingAlerts, adding: alert, at: Date())
            return
        }
        guard NotchAlertLogic.shouldPreempt(current: currentAlert, incoming: alert) else { return }
        alertPinned = false
        currentAlert = alert
        syncFrames()
        scheduleAlertHide(after: alert.autoHide)
    }

    private func flushPendingAlert() {
        guard !isExpanded, currentAlert == nil else { return }
        let (next, rest) = NotchAlertLogic.dequeue(pendingAlerts, now: Date())
        pendingAlerts = rest
        if let next { postAlert(next) }
    }

    private func scheduleAlertHide(after delay: TimeInterval) {
        alertWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hideAlert() }
        alertWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func hideAlert() {
        guard !alertPinned else { return }
        currentAlert = nil
        alertWorkItem = nil
        syncFrames()
        flushPendingAlert()
    }

    func alertHover(_ hovering: Bool) {
        guard currentAlert != nil else { return }
        alertPinned = hovering
        if hovering {
            alertWorkItem?.cancel()
        } else {
            scheduleAlertHide(after: 1.2)
        }
    }

    func alertTapped(_ alert: NotchAlert) {
        dismissAlert()
        guard alert.settingsTab != nil else { return }
        openCustomization()
    }

    func dismissAlert() {
        alertPinned = false
        hideAlert()
    }

    func shutdown() {
        stopped = true
        hostDragRemoval?.cancel(); hostDragRemoval = nil
        context.sharedState.stopObserving(contextObserver); contextObserver = nil
        glanceTask?.cancel(); glanceTask = nil
        requests.shutdown()
        privacy.shutdown()
        surfaceSnapshots = [:]
        if let dragMonitor { NSEvent.removeMonitor(dragMonitor) }
        dragMonitor = nil
        stopMoveMonitor()
        alertDetectors?.stop()
        alertDetectors = nil
        alertWorkItem?.cancel()
        alertWorkItem = nil
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        if let spaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver)
        }
        spaceObserver = nil
        if let shelfOperationObserver { NotchWorkerIPC.stopObserving(shelfOperationObserver) }
        shelfOperationObserver = nil
        if let surfaceSettingsObserver { NotchWorkerIPC.stopObserving(surfaceSettingsObserver) }
        surfaceSettingsObserver = nil
        collapseWorkItem?.cancel()
        collapseWorkItem = nil
        panelSettleWorkItem?.cancel()
        panelSettleWorkItem = nil
        gateWorkItem?.cancel()
        gateWorkItem = nil
        browser?.shutdown()
        browser = nil
        browserEngine?.stop()
        isSharing = false
        sharePickerDelegate = nil
        shareStagedFiles = nil
        dragStagedFiles = nil
        store.shutdown()
        for panel in panels.values { panel.orderOut(nil) }
        panels.removeAll()
        collapsedSizes.removeAll()
    }

    private func flag(_ key: String, default def: Bool) -> Bool {
        context.defaults.object(forKey: key) as? Bool ?? def
    }
    private var openOnDrag: Bool { flag(AppStorageKeys.Notch.shelfOpenOnDrag, default: true) }
    private var openOnHover: Bool { flag(AppStorageKeys.Notch.shelfOpenOnHover, default: true) }
    private var requireOption: Bool {
        flag(AppStorageKeys.Notch.shelfRequireOption, default: false)
    }
    private var removeAfterDragOut: Bool {
        flag(AppStorageKeys.Notch.shelfRemoveAfterDragOut, default: true)
    }
    private var showOnExternal: Bool {
        flag(AppStorageKeys.Notch.shelfShowOnExternal, default: true)
    }
    private var hapticsOn: Bool { flag(AppStorageKeys.Notch.shelfHaptics, default: true) }
    private var keepDuration: ShelfKeepDuration {
        ShelfKeepDuration(
            rawValue: context.defaults.string(forKey: AppStorageKeys.Notch.shelfKeepDuration)
                ?? "")
            ?? .forever
    }

    func rebuildPanels() {
        if hostOwned { updateFullScreenVisibility(); onPanelStateChanged?(); return }
        activeTab = NotchTab.validSelection(activeTab, visible: visibleTabs)
        let builtin = NSScreen.screens.first {
            $0.displayID.map { CGDisplayIsBuiltin($0) != 0 } ?? false
        }
        builtinDisplayID = builtin?.displayID
        var wanted: Set<CGDirectDisplayID> = []
        if let builtin, let id = builtin.displayID {
            wanted.insert(id)
            placePanel(on: builtin, id: id)
        }
        if showOnExternal {
            for screen in NSScreen.screens {
                guard let id = screen.displayID, id != builtinDisplayID else { continue }
                wanted.insert(id)
                placePanel(on: screen, id: id)
            }
        }
        for id in panels.keys where !wanted.contains(id) {
            panels.removeValue(forKey: id)?.orderOut(nil)
            collapsedSizes.removeValue(forKey: id)
        }
        refreshInteractionRects()
        updateFullScreenVisibility()
    }

    private func refreshInteractionRects() {
        var rects: [CGDirectDisplayID: CGRect] = [:]
        for (id, panel) in panels {
            let margin = hidePolicy.trackingMargin
            rects[id] = panel.frame.insetBy(dx: -margin, dy: -margin)
        }
        interactionRects = rects
    }

    private static let managedDisplaySpaces: () -> [[String: Any]]? = {
        guard let handle = dlopen(nil, RTLD_NOW),
            let defaultConnection = dlsym(handle, "_CGSDefaultConnection"),
            let copySpaces = dlsym(handle, "CGSCopyManagedDisplaySpaces")
        else { return { nil } }
        typealias ConnectionFn = @convention(c) () -> Int32
        typealias CopyFn = @convention(c) (Int32) -> CFArray?
        let connectionFn = unsafeBitCast(defaultConnection, to: ConnectionFn.self)
        let copyFn = unsafeBitCast(copySpaces, to: CopyFn.self)
        return { copyFn(connectionFn()) as? [[String: Any]] }
    }()

    private func isFullScreenSpace(_ screen: NSScreen) -> Bool {
        guard let id = screen.displayID,
            let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue(),
            let uuidString = CFUUIDCreateString(nil, uuid) as String?,
            let displays = Self.managedDisplaySpaces()
        else { return false }
        for display in displays {
            guard (display["Display Identifier"] as? String) == uuidString,
                let current = display["Current Space"] as? [String: Any],
                let type = current["type"] as? Int
            else { continue }
            return type == 4
        }
        return false
    }

    private func updateFullScreenVisibility() {
        for screen in NSScreen.screens {
            guard let id = screen.displayID else { continue }
            let fullScreen = isFullScreenSpace(screen)
            if fullScreen {
                fullScreenDisplays.insert(id)
                if expandedDisplay == id { collapseNow() }
            } else {
                fullScreenDisplays.remove(id)
            }
            panels[id]?.alphaValue = fullScreen ? 0 : 1
        }
        syncFrames()
    }

    private func placePanel(on screen: NSScreen, id: CGDirectDisplayID) {
        let base = NotchGeometry.collapsedSize(
            screenWidth: screen.frame.width,
            leftAreaWidth: screen.auxiliaryTopLeftArea?.width,
            rightAreaWidth: screen.auxiliaryTopRightArea?.width,
            safeAreaTop: screen.safeAreaInsets.top)
        collapsedSizes[id] = base
        let panel = panels[id] ?? makePanel(id: id)
        if let host = panel.contentView?.subviews.first as? NSHostingView<AnyView> {
            host.rootView = AnyView(
                NotchShelfContentView(
                    controller: self, displayID: id, collapsedBase: base,
                    isBuiltin: id == builtinDisplayID))
        }
        applyExactFrame(panel, screen: screen, id: id)
        updateInteractiveShape(panel, id: id)
    }

    private func makePanel(id: CGDirectDisplayID) -> NSPanel {
        let panel = NotchPanel(
            contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovable = false
        panel.ignoresMouseEvents = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 8)
        panel.collectionBehavior = [
            .fullScreenAuxiliary, .stationary, .canJoinAllSpaces, .ignoresCycle,
        ]

        let container = ShelfDropCatcherView()
        container.controller = self
        container.registerForDraggedTypes(Self.acceptedDraggedTypes)

        let host = ShelfHostingView(rootView: AnyView(EmptyView()))
        host.sizingOptions = []
        host.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            host.topAnchor.constraint(equalTo: container.topAnchor),
            host.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        panel.contentView = container
        panels[id] = panel
        NotchWorkerPresentation.orderFrontRegardless(panel)
        return panel
    }

    private static let acceptedDraggedTypes: [NSPasteboard.PasteboardType] = {
        var types: [NSPasteboard.PasteboardType] = [.fileURL, .string]
        types += NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
        return types
    }()

    private func shapeSize(
        for id: CGDirectDisplayID, expanded: Bool, alert: NotchAlert?
    ) -> CGSize {
        let base = collapsedSizes[id] ?? NotchGeometry.fallbackSize
        if expanded {
            return expandedSize(on: id)
        }
        if alert != nil, id == builtinDisplayID { return NotchGeometry.alertDropSize }
        return NotchGeometry.collapsedSize(base: base, wingWidth: glanceWingWidth)
    }

    private func targetShapeSize(for id: CGDirectDisplayID) -> CGSize {
        shapeSize(
            for: id, expanded: expandedDisplay == id, alert: currentAlert)
    }

    func measureHomeContent(_ height: Double) {
        let value = CGFloat(height) + 14
        guard homeContentHeight.map({ abs($0 - value) >= 1 }) ?? true else { return }
        homeContentHeight = value
        updatePanelFrames()
    }

    func configureHostDisplays(_ displays: [NotchPanelDisplay]) {
        hostDisplaySizes = Dictionary(
            uniqueKeysWithValues: displays.map {
                ($0.displayID, CGSize(width: $0.width, height: $0.height))
            })
        collapsedSizes = Dictionary(
            uniqueKeysWithValues: displays.map { ($0.displayID, $0.collapsedSize) })
        builtinDisplayID = displays.first(where: \.isBuiltin)?.displayID
    }

    var hostHeldOpen: Bool { isSharing || browserHoldsOpen || layoutEditing }

    func hostPanelVisible(_ display: NotchPanelDisplay) -> Bool {
        !stopped && (display.isBuiltin || showOnExternal)
            && !fullScreenDisplays.contains(display.displayID)
    }

    func hostShapeSize(_ display: NotchPanelDisplay) -> CGSize {
        shapeSize(
            for: display.displayID, expanded: expandedDisplay == display.displayID,
            alert: currentAlert)
    }

    func hostPointer(_ pointer: NotchPanelPointer, display: NotchPanelDisplay) {
        hostOption = pointer.option
        let collapsed = NotchGeometry.collapsedSize(
            base: display.collapsedSize, wingWidth: glanceWingWidth)
        let expanded = expandedSize(on: display.displayID)
        let point = CGPoint(x: pointer.x, y: pointer.y)
        let collapsedFrame = CGRect(
            x: (display.width - collapsed.width) / 2, y: 0, width: collapsed.width,
            height: collapsed.height)
        let expandedFrame = CGRect(
            x: (display.width - expanded.width) / 2, y: 0, width: expanded.width,
            height: expanded.height)
        if pointer.draggingFiles, openOnDrag, optionSatisfied(),
            NotchGeometry.interactionFrame(around: collapsedFrame).contains(point)
        {
            expand(on: display.displayID, preferredTab: .files)
        } else if expandedDisplay == display.displayID {
            applyProximity(
                NotchGeometry.proximity(
                    point: point, collapsedFrame: collapsedFrame, expandedFrame: expandedFrame,
                    keepInset: hidePolicy.keepInset), on: display.displayID)
        } else if currentAlert == nil {
            hoverChanged(
                NotchGeometry.openFrame(around: collapsedFrame).contains(point),
                on: display.displayID)
        }
    }

    func expandedSize(on id: CGDirectDisplayID) -> CGSize {
        let base = collapsedSizes[id] ?? NotchGeometry.fallbackSize
        let requested = NotchGeometry.expandedShapeSize(
            tab: activeTab, hasMusic: false, notchHeight: base.height,
            browserSize: browserSize(on: id), layout: visibleSurfaceLayout, editing: layoutEditing,
            homeHeight: homeContentHeight)
        let screenSize =
            hostDisplaySizes[id]
            ?? (startsServices
                ? NSScreen.screens.first(where: { $0.displayID == id })?.frame.size : nil)
        guard let screenSize else { return requested }
        return CGSize(
            width: min(requested.width, screenSize.width - 48),
            height: min(requested.height, screenSize.height - (activeTab == .browser ? 12 : 48)))
    }

    private func applyExactFrame(_ panel: NSPanel, screen: NSScreen, id: CGDirectDisplayID) {
        let size = NotchGeometry.panelSize(forShape: panelShape(for: id))
        applyFrame(panel, screen: screen, size: size)
    }

    private func applyFrame(_ panel: NSPanel, screen: NSScreen, size: CGSize) {
        panel.setFrame(
            NSRect(
                origin: NotchGeometry.origin(screenFrame: screen.frame, panelSize: size),
                size: size),
            display: true)
    }

    func hostCapacity(_ display: NotchPanelDisplay) -> CGSize {
        let capacity = CGSize(
            width: min(1200, display.width - 48),
            height: min(display.collapsedHeight + 760, display.height - 48))
        guard browserEngine != nil else { return capacity }
        return NotchGeometry.union(
            capacity,
            NotchBrowserGeometry.shapeSize(
                browser: browserSize(on: display.displayID), notchHeight: display.collapsedHeight))
    }

    private func panelShape(for id: CGDirectDisplayID) -> CGSize {
        let notchHeight = (collapsedSizes[id] ?? NotchGeometry.fallbackSize).height
        let screenSize =
            NSScreen.screens.first(where: { $0.displayID == id })?.frame.size
            ?? CGSize(width: 1248, height: 900)
        let capacity = CGSize(
            width: min(1200, screenSize.width - 48),
            height: min(notchHeight + 760, screenSize.height - 48))
        return NotchGeometry.union(
            capacity,
            NotchGeometry.panelShape(
                browserShape: browser.map { _ in
                    NotchBrowserGeometry.shapeSize(
                        browser: browserSize(on: id), notchHeight: notchHeight)
                }))
    }

    func browserSize(on id: CGDirectDisplayID) -> CGSize {
        NotchBrowserGeometry.clamp(
            browser?.size ?? browserEngine?.size ?? NotchBrowserGeometry.defaultSize,
            screen: browserArea(on: id))
    }

    private func browserArea(on id: CGDirectDisplayID?) -> CGSize? {
        let size =
            id.flatMap { hostDisplaySizes[$0] }
            ?? (startsServices
                ? NSScreen.screens.first(where: { $0.displayID == id })?.frame.size : nil)
        guard let size else { return nil }
        let notchHeight = (id.flatMap { collapsedSizes[$0] } ?? NotchGeometry.fallbackSize).height
        return NotchBrowserGeometry.available(screen: size, notchHeight: notchHeight)
    }

    private func browserScreenSize() -> CGSize? {
        browserArea(on: expandedDisplay ?? builtinDisplayID)
    }

    private func updatePanelFrames() {
        onPanelStateChanged?()
        guard !hostOwned else { return }
        var settling = false
        for screen in NSScreen.screens {
            guard let id = screen.displayID, let panel = panels[id] else { continue }
            let wanted = NotchGeometry.panelSize(forShape: panelShape(for: id))
            let grown = NotchGeometry.union(panel.frame.size, wanted)
            if grown != panel.frame.size { applyFrame(panel, screen: screen, size: grown) }
            if grown != wanted { settling = true }
        }
        panelSettleWorkItem?.cancel()
        panelSettleWorkItem = nil
        refreshInteractionRects()
        guard settling else { return }
        let work = DispatchWorkItem { [weak self] in self?.settlePanelFrames() }
        panelSettleWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.panelSettleDelay, execute: work)
    }

    static let panelSettleDelay: TimeInterval = 0.45

    private func settlePanelFrames() {
        panelSettleWorkItem = nil
        for screen in NSScreen.screens {
            guard let id = screen.displayID, let panel = panels[id] else { continue }
            let wanted = NotchGeometry.panelSize(forShape: panelShape(for: id))
            if panel.frame.size != wanted { applyFrame(panel, screen: screen, size: wanted) }
        }
        refreshInteractionRects()
    }

    private func updateKeyFocus() {
        for (id, panel) in panels {
            guard let panel = panel as? NotchPanel else { continue }
            let accepts = expandedDisplay == id && activeTab == .browser && browser != nil
            panel.acceptsKeyFocus = accepts
            panel.keyEquivalentHandler =
                accepts
                ? { [weak self] event in self?.browser?.handleKeyEquivalent(event) ?? false }
                : nil
            guard !accepts, panel.isKeyWindow else { continue }
            panel.orderOut(nil)
            NotchWorkerPresentation.orderFrontRegardless(panel)
        }
    }

    func makeExpandedPanelKey() {
        guard let id = expandedDisplay, let panel = panels[id] as? NotchPanel,
            panel.acceptsKeyFocus
        else { return }
        NotchWorkerPresentation.makeKey(panel)
    }

    func attachBrowser(_ store: NotchBrowserStore?) {
        guard browser !== store else { return }
        browser = store
        store?.screenSize = { [weak self] in self?.browserScreenSize() }
        store?.onSizeChange = { [weak self] in self?.syncFrames() }
        store?.requestKeyFocus = { [weak self] in self?.makeExpandedPanelKey() }
        if store == nil, activeTab == .browser { activeTab = .home }
        syncFrames()
    }

    private var hidePolicy: NotchHidePolicy {
        NotchHidePolicy.policy(for: browser == nil && browserEngine == nil ? .home : activeTab)
    }

    private var browserHoldsOpen: Bool {
        activeTab == .browser && (browser?.holdsOpen == true || browserEngine?.held == true)
    }

    private func syncFrames() {
        updatePanelFrames()
        for screen in NSScreen.screens {
            guard let id = screen.displayID, let panel = panels[id] else { continue }
            updateInteractiveShape(panel, id: id)
        }
        updateKeyFocus()
        refreshMouseTransparency()
    }

    private func updateInteractiveShape(_ panel: NSPanel, id: CGDirectDisplayID) {
        guard let catcher = panel.contentView as? ShelfDropCatcherView else { return }
        let shape = targetShapeSize(for: id)
        guard catcher.interactiveShapeSize != shape else { return }
        catcher.interactiveShapeSize = shape
        refreshMouseTransparency()
    }

    private func refreshMouseTransparency() {
        let cursor = NSEvent.mouseLocation
        for screen in NSScreen.screens {
            guard let id = screen.displayID, let panel = panels[id] else { continue }
            let allowMouse: Bool
            if expandedDisplay == id {
                allowMouse = NotchGeometry.expandedAcceptsPointer(
                    cursor, shapeFrame: shapeFrame(of: panel),
                    buttonPressed: NSEvent.pressedMouseButtons != 0,
                    heldOpen: isSharing || browserHoldsOpen || layoutEditing)
            } else if currentAlert != nil, id == builtinDisplayID {
                allowMouse = shapeFrame(of: panel).contains(cursor)
            } else {
                allowMouse = false
            }
            let ignores = fullScreenDisplays.contains(id) || !allowMouse
            if panel.ignoresMouseEvents != ignores { panel.ignoresMouseEvents = ignores }
        }
    }

    private func optionSatisfied() -> Bool {
        !requireOption || (hostOwned ? hostOption : NSEvent.modifierFlags.contains(.option))
    }

    var isExpanded: Bool { expandedDisplay != nil }

    func isExpanded(on id: CGDirectDisplayID) -> Bool { expandedDisplay == id }

    func isHovering(on id: CGDirectDisplayID) -> Bool { hoverDisplay == id }

    func expand(on id: CGDirectDisplayID, preferredTab: NotchTab? = nil) {
        collapseWorkItem?.cancel()
        gateWorkItem?.cancel()
        gateWorkItem = nil
        purgeExpired()
        alertWorkItem?.cancel()
        alertWorkItem = nil
        gate.forceOpen()
        gateDisplay = id
        if let preferredTab {
            activeTab = preferredTab
        }
        guard expandedDisplay != id else { syncFrames(); return }
        hoverDisplay = nil
        currentAlert = nil
        expandedDisplay = id
        syncFrames()
        fireHaptic()
    }

    func collapseAfterDelay(_ delay: TimeInterval = 0.35) {
        collapseWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.collapseNow() }
        collapseWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func collapseNow() {
        guard isExpanded, !isSharing else { return }
        layoutEditing = false
        expandedDisplay = nil
        selectedIDs = []
        gate.forceClosed()
        gateWorkItem?.cancel()
        gateWorkItem = nil
        syncFrames()
        flushPendingAlert()
    }

    func hoverChanged(_ hovering: Bool, on id: CGDirectDisplayID?) {
        let hoverState = hovering && !isExpanded && currentAlert == nil
        let next = hoverState ? id : nil
        if hoverDisplay != next { hoverDisplay = next }
        guard !isExpanded else { return }
        applyProximity(hovering ? .open : .outside, on: id)
    }

    private func monotonicNow() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

    private func applyProximity(_ raw: NotchProximity, on id: CGDirectDisplayID?) {
        var proximity = raw
        if !gate.isOpen, proximity == .open, !(openOnHover && optionSatisfied()) {
            proximity = .outside
        }
        if proximity != .outside, let id { gateDisplay = id }
        gate.closeGrace = hidePolicy.closeGrace
        handleGate(gate.sample(proximity, now: monotonicNow()))
    }

    private func handleGate(_ transition: NotchGateTransition) {
        switch transition {
        case .schedule(let deadline):
            gateWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.fireGate() }
            gateWorkItem = work
            let delay = max(0, deadline - monotonicNow())
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        case .cancelPending:
            gateWorkItem?.cancel()
            gateWorkItem = nil
        case .none, .opened, .closed:
            break
        }
    }

    private func fireGate() {
        gateWorkItem = nil
        let transition = gate.fire(now: monotonicNow())
        switch transition {
        case .opened:
            if let gateDisplay { expand(on: gateDisplay) }
        case .closed:
            if isSharing || browserHoldsOpen || layoutEditing {
                gate.forceOpen()
            } else {
                collapseNow()
            }
        case .schedule:
            handleGate(transition)
        case .none, .cancelPending:
            break
        }
    }

    private func handleMouseMoved() {
        let point = NSEvent.mouseLocation
        let inside = interactionRects.values.contains { $0.contains(point) }
        if !inside, !pointerInsideInterest { return }
        pointerInsideInterest = inside
        refreshMouseTransparency()
        if let expandedDisplay, let frames = frames(for: expandedDisplay) {
            applyProximity(
                NotchGeometry.proximity(
                    point: point, collapsedFrame: frames.collapsed,
                    expandedFrame: frames.expanded, keepInset: hidePolicy.keepInset),
                on: expandedDisplay)
        } else if currentAlert == nil {
            let id = notchDisplay(near: point)
            let near =
                id.flatMap { frames(for: $0) }
                .map { NotchGeometry.openFrame(around: $0.collapsed).contains(point) } ?? false
            hoverChanged(near, on: id)
        }
    }

    private func notchDisplay(near point: CGPoint) -> CGDirectDisplayID? {
        panels.keys.first { id in
            guard let frames = frames(for: id) else { return false }
            return NotchGeometry.interactionFrame(around: frames.collapsed).contains(point)
        }
    }

    private func frames(for id: CGDirectDisplayID) -> (collapsed: CGRect, expanded: CGRect)? {
        guard let screen = NSScreen.screens.first(where: { $0.displayID == id })
        else { return nil }
        let collapsedSize = NotchGeometry.collapsedSize(
            base: collapsedSizes[id] ?? NotchGeometry.fallbackSize,
            wingWidth: glanceWingWidth)
        let collapsed = CGRect(
            origin: NotchGeometry.origin(screenFrame: screen.frame, panelSize: collapsedSize),
            size: collapsedSize)
        let expandedSize = shapeSize(
            for: id, expanded: true, alert: nil)
        let expanded = CGRect(
            origin: NotchGeometry.origin(screenFrame: screen.frame, panelSize: expandedSize),
            size: expandedSize)
        return (collapsed, expanded)
    }

    private func startMoveMonitor() {
        guard moveMonitorGlobal == nil else { return }
        moveMonitorGlobal = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.handleMouseMoved() }
        }
        moveMonitorLocal = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) {
            [weak self] event in
            MainActor.assumeIsolated { self?.handleMouseMoved() }
            return event
        }
    }

    private func stopMoveMonitor() {
        if let moveMonitorGlobal { NSEvent.removeMonitor(moveMonitorGlobal) }
        if let moveMonitorLocal { NSEvent.removeMonitor(moveMonitorLocal) }
        moveMonitorGlobal = nil
        moveMonitorLocal = nil
    }

    private func handleGlobalMouse(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            lastDragChangeCount = NSPasteboard(name: .drag).changeCount
            internalDragItemIDs = []
            let point = NSEvent.mouseLocation
            if !isExpanded, currentAlert == nil, let id = notchDisplay(near: point),
                let frames = frames(for: id),
                NotchGeometry.openFrame(around: frames.collapsed).contains(point)
            {
                expand(on: id)
            }
        case .leftMouseDragged:
            guard openOnDrag else { return }
            let point = NSEvent.mouseLocation
            guard let id = notchDisplay(near: point), isNearNotch(point, on: id),
                NSPasteboard(name: .drag).changeCount != lastDragChangeCount, optionSatisfied()
            else { return }
            activeTab = .files
            expand(on: id)
        default:
            break
        }
    }

    private func isNearNotch(_ point: CGPoint, on id: CGDirectDisplayID) -> Bool {
        guard let frames = frames(for: id) else { return false }
        return NotchGeometry.interactionFrame(around: frames.collapsed).contains(point)
    }

    private func shapeFrame(of panel: NSPanel) -> CGRect {
        guard let catcher = panel.contentView as? ShelfDropCatcherView,
            let shape = catcher.interactiveShapeSize
        else { return panel.frame }
        return CGRect(
            x: panel.frame.midX - shape.width / 2, y: panel.frame.maxY - shape.height,
            width: shape.width, height: shape.height)
    }

    private func purgeExpired() {
        store.purgeExpired(keep: keepDuration)
    }

    private func fireHaptic() {
        guard hapticsOn else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
    }

    func selectTab(_ tab: NotchTab) {
        guard visibleTabs.contains(tab) else { return }
        activeTab = tab
        syncFrames()
    }

    func thumbnail(for item: ShelfItem) async -> NSImage? {
        let staged: ShelfStagedFiles
        do {
            staged = try store.withActionSelection(itemIDs: [item.id]) { selection in
                try selection.stagedFiles()
            }
        } catch {
            return nil
        }
        guard let url = staged.urls.first else { return nil }
        let image = await ShelfThumbnails.thumbnail(for: url, cacheKey: item.id.uuidString)
        withExtendedLifetime(staged) {}
        return image
    }

    func toggleSelection(_ item: ShelfItem) {
        if selectedIDs.contains(item.id) {
            selectedIDs.remove(item.id)
        } else {
            selectedIDs.insert(item.id)
        }
    }

    private func group(for item: ShelfItem) -> [ShelfItem] {
        guard selectedIDs.contains(item.id) else { return [item] }
        return items.filter { selectedIDs.contains($0.id) }
    }

    func open(_ item: ShelfItem) {
        guard let error = perform(.open, items: group(for: item), anchor: item) else {
            shelfOperationError = nil
            collapseNow()
            return
        }
        presentShelfFailure(error)
    }

    func dismissShelfFailure() {
        shelfOperationError = nil
    }

    private func presentShelfFailure(_ error: String) {
        shelfOperationError = error
    }

    func reveal(_ item: ShelfItem) {
        guard let error = perform(.reveal, items: group(for: item), anchor: item) else {
            shelfOperationError = nil
            collapseNow()
            return
        }
        presentShelfFailure(error)
    }

    @discardableResult
    private func removeMembers(_ members: [ShelfItem]) -> Bool {
        do {
            try store.remove(members)
            selectedIDs.subtract(members.map(\.id))
            items = store.items
            shelfOperationError = nil
            return true
        } catch {
            items = store.items
            presentShelfFailure(error.localizedDescription)
            return false
        }
    }

    func remove(_ item: ShelfItem) {
        guard removeMembers(group(for: item)) else { return }
        collapseNow()
    }

    func share(_ item: ShelfItem) {
        if let error = perform(.share, items: group(for: item), anchor: item) {
            presentShelfFailure(error)
        } else {
            shelfOperationError = nil
        }
    }

    func hostSelect(_ ids: Set<UUID>) { selectedIDs = ids }
    func requireShelfCLIAccess() throws {
        guard !stopped, !store.actionSelectionRetained else {
            throw CLIFailure.unavailable("a native shelf action is still using the selected files")
        }
    }
    func shareCLIItems(_ ids: [UUID]) async throws {
        if let panelEngine, panelEngine.attached { try await panelEngine.shareCLI(ids); return }
        guard !stopped, !isSharing else { throw ShelfActionSelectionError.busy }
        if let error = perform(.share, itemIDs: Set(ids)) {
            throw CLIFailure.unavailable(error)
        }
    }

    private func performShelfOperation(_ info: [AnyHashable: Any]) {
        guard
            let outcome = ShelfOperationRequestRouter.route(
                info, isSharing: isSharing,
                perform: { [weak self] operation, itemIDs in
                    self?.perform(operation, itemIDs: itemIDs)
                        ?? "the shelf operation could not start"
                })
        else { return }
        if let requestID = outcome.requestID {
            NotchWorkerIPC.post(
                NotchWorkerIPC.Name.shelfOperationResult,
                userInfo: ShelfItemOperationExecution.resultPayload(
                    requestID: requestID, ok: outcome.error == nil, error: outcome.error))
        }
        guard outcome.error == nil else { return }
        if outcome.operation != .share { collapseNow() }
    }

    private func operationError(_ operation: ShelfItemOperation, completed: Bool) -> String? {
        guard !completed else { return nil }
        return operation == .share
            ? "the shelf share picker could not open" : "the shelf operation could not start"
    }

    private func perform(_ operation: ShelfItemOperation, itemIDs: Set<UUID>) -> String? {
        do {
            return try store.withActionSelection(itemIDs: itemIDs) { action in
                items = store.items
                return perform(operation, selection: action, anchor: action.items[0])
            }
        } catch {
            return error.localizedDescription
        }
    }

    private func perform(
        _ operation: ShelfItemOperation, items members: [ShelfItem], anchor item: ShelfItem
    ) -> String? {
        do {
            return try store.withActionSelection(itemIDs: Set(members.map(\.id))) { selection in
                items = store.items
                let anchor = selection.items.first { $0.id == item.id } ?? selection.items[0]
                return perform(operation, selection: selection, anchor: anchor)
            }
        } catch {
            return error.localizedDescription
        }
    }

    private func perform(
        _ operation: ShelfItemOperation, selection: ShelfStoreActionSelection,
        anchor item: ShelfItem
    ) -> String? {
        if operation == .share {
            do {
                let staged = try selection.stagedFiles()
                let completed = ShelfItemOperationExecution.perform(
                    operation, urls: staged.urls,
                    share: { [weak self] _ in
                        self?.showSharePicker(staged, anchor: item, selection: selection.snapshot)
                            ?? false
                    })
                return operationError(operation, completed: completed)
            } catch {
                return error.localizedDescription
            }
        }
        let urls: [URL]
        do {
            urls = try selection.fileURLs()
        } catch {
            return error.localizedDescription
        }
        let completed = ShelfItemOperationExecution.perform(operation, urls: urls)
        return operationError(operation, completed: completed)
    }

    private func showSharePicker(
        _ staged: ShelfStagedFiles, anchor item: ShelfItem, selection: ShelfPinnedSelection
    ) -> Bool {
        guard !isSharing else { return false }
        let mouse = NSEvent.mouseLocation
        let panel =
            panels.values.first { $0.frame.contains(mouse) }
            ?? builtinDisplayID.flatMap { panels[$0] }
        guard let panel, let view = panel.contentView else { return false }
        guard store.retainActionSelection(selection) else { return false }
        isSharing = true
        shareStagedFiles = staged
        collapseWorkItem?.cancel()
        let delegate = SharePickerDelegate { [weak self] in
            self?.isSharing = false
            self?.sharePickerDelegate = nil
            self?.store.releaseActionSelection()
            self?.shareStagedFiles = nil
            self?.collapseAfterDelay()
        }
        sharePickerDelegate = delegate
        let picker = NSSharingServicePicker(items: staged.urls)
        picker.delegate = delegate
        let size = view.bounds.size
        let index = items.firstIndex(where: { $0.id == item.id }) ?? 0
        let position = NotchGeometry.itemPosition(stored: item.position, index: index, in: size)
        let anchor = NSRect(
            x: position.x - 20, y: size.height - position.y - 20, width: 40, height: 40)
        picker.show(relativeTo: anchor, of: view, preferredEdge: .minY)
        return true
    }

    func canvasDrag(_ item: ShelfItem, to location: CGPoint, in size: CGSize) {
        if dragStartPositions.isEmpty {
            let memberIDs = Set(group(for: item).map(\.id))
            for (index, member) in items.enumerated() where memberIDs.contains(member.id) {
                dragStartPositions[member.id] = NotchGeometry.itemPosition(
                    stored: member.position, index: index, in: size)
            }
            dragPointerStart = location
        }
        guard let pointerStart = dragPointerStart else { return }
        let dx = location.x - pointerStart.x
        let dy = location.y - pointerStart.y
        for (id, start) in dragStartPositions {
            livePositions[id] = CGPoint(x: start.x + dx, y: start.y + dy)
        }
    }

    func endCanvasDrag() {
        store.setPositions(livePositions)
        if !livePositions.isEmpty { items = store.items }
        livePositions = [:]
        dragStartPositions = [:]
        dragPointerStart = nil
    }

    func beginExternalDrag(of item: ShelfItem) {
        let members = group(for: item)
        livePositions = [:]
        dragStartPositions = [:]
        dragPointerStart = nil
        let mouse = NSEvent.mouseLocation
        let panel =
            panels.values.first { $0.frame.contains(mouse) }
            ?? builtinDisplayID.flatMap { panels[$0] }
        guard let catcher = panel?.contentView as? ShelfDropCatcherView,
            let event = NSApp.currentEvent
        else { return }
        let staged: ShelfStagedFiles
        do {
            staged = try store.withActionSelection(itemIDs: Set(members.map(\.id))) { selection in
                try selection.stagedFiles()
            }
        } catch {
            presentShelfFailure(error.localizedDescription)
            return
        }
        dragStagedFiles = staged
        internalDragItemIDs = Set(members.map(\.id))
        if removeAfterDragOut { pendingDragOutIDs = Set(members.map(\.id)) }
        catcher.beginDrag(of: staged.urls, event: event)
    }

    func externalDragEnded(at point: CGPoint, operation: NSDragOperation) {
        defer { dragStagedFiles = nil }
        internalDragItemIDs = []
        guard !pendingDragOutIDs.isEmpty else { return }
        let ids = pendingDragOutIDs
        pendingDragOutIDs = []
        let insideShelf = panels.values.contains { shapeFrame(of: $0).contains(point) }
        guard !insideShelf, operation != [] else { return }
        let members = items.filter { ids.contains($0.id) }
        guard !members.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.removeMembers(members)
        }
    }

    private func internalDragItem(matching url: URL) -> ShelfItem? {
        if let match = items.first(where: {
            internalDragItemIDs.contains($0.id) && $0.name == url.lastPathComponent
        }) {
            return match
        }
        return store.item(forFileURL: url)
    }

    @discardableResult
    func handleDrop(from pasteboard: NSPasteboard, at location: CGPoint? = nil) -> Bool {
        let objects =
            pasteboard.readObjects(
                forClasses: [NSFilePromiseReceiver.self, NSURL.self, NSString.self],
                options: [.urlReadingFileURLsOnly: true]) ?? []
        var handled = false
        for object in objects {
            switch object {
            case let receiver as NSFilePromiseReceiver:
                handled = true
                receivePromise(receiver, at: location)
            case let url as URL:
                handled = true
                if let location, let existing = internalDragItem(matching: url) {
                    pendingDragOutIDs.remove(existing.id)
                    internalDragItemIDs.remove(existing.id)
                    store.setPosition(location, for: existing)
                    items = store.items
                } else {
                    addFile(at: url, location: location)
                }
            case let text as String:
                handled = true
                addText(text, location: location)
            default:
                break
            }
        }
        return handled
    }

    private func receivePromise(_ receiver: NSFilePromiseReceiver, at location: CGPoint?) {
        let id = UUID()
        guard let destination = store.promiseDestination(id: id) else { return }
        receiver.receivePromisedFiles(
            atDestination: destination, options: [:], operationQueue: .main
        ) {
            [weak self] url, error in
            Task { @MainActor in
                guard let self else { return }
                guard error == nil else {
                    self.store.discardPromiseDestination(id: id)
                    self.presentShelfFailure(
                        error?.localizedDescription ?? "the promised file failed")
                    return
                }
                self.store.adoptWhenAvailable(fileAt: url, id: id) { [weak self] item in
                    guard let self else { return }
                    guard let item else {
                        self.items = self.store.items
                        self.presentShelfFailure(
                            "the promised file could not be added to the shelf")
                        return
                    }
                    if let location { self.store.setPosition(location, for: item) }
                    self.items = self.store.items
                    self.shelfOperationError = nil
                    self.fireHaptic()
                }
            }
        }
    }

    private func addFile(at url: URL, location: CGPoint?) {
        guard let item = store.addCopy(of: url) else { return }
        if let location { store.setPosition(location, for: item) }
        items = store.items
        fireHaptic()
    }

    private func addText(_ text: String, location: CGPoint?) {
        guard let item = store.addText(text) else { return }
        if let location { store.setPosition(location, for: item) }
        items = store.items
        fireHaptic()
    }
}

final class SharePickerDelegate: NSObject, NSSharingServicePickerDelegate {
    private let onEnd: @MainActor @Sendable () -> Void

    init(onEnd: @escaping @MainActor @Sendable () -> Void) {
        self.onEnd = onEnd
    }

    func sharingServicePicker(
        _ sharingServicePicker: NSSharingServicePicker, didChoose service: NSSharingService?
    ) {
        let onEnd = onEnd
        Task { @MainActor in onEnd() }
    }
}

@MainActor
final class ShelfHostingView: NSHostingView<AnyView> {
    override func cursorUpdate(with event: NSEvent) {}
}

@MainActor
final class ShelfDropCatcherView: NSView {
    weak var controller: NotchShelfController?
    var interactiveShapeSize: CGSize?

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let shape = interactiveShapeSize else { return super.hitTest(point) }
        let local = convert(point, from: superview)
        let rect = CGRect(
            x: (bounds.width - shape.width) / 2, y: bounds.height - shape.height,
            width: shape.width, height: shape.height)
        guard rect.contains(local) else { return nil }
        return super.hitTest(point)
    }

    override func cursorUpdate(with event: NSEvent) {}

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        dropOperation(for: sender)
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        dropOperation(for: sender)
    }

    private func dropOperation(for sender: NSDraggingInfo) -> NSDragOperation {
        guard let shape = interactiveShapeSize else { return .copy }
        let local = convert(sender.draggingLocation, from: nil)
        let rect = CGRect(
            x: (bounds.width - shape.width) / 2, y: bounds.height - shape.height,
            width: shape.width, height: shape.height
        )
        let interactionFrame = NotchGeometry.interactionFrame(around: rect)
        return interactionFrame.contains(local) ? .copy : []
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let windowPoint = convert(sender.draggingLocation, from: nil)
        let shapeInset = interactiveShapeSize.map { (bounds.width - $0.width) / 2 } ?? 0
        let location = CGPoint(
            x: windowPoint.x - shapeInset, y: bounds.height - windowPoint.y)
        return controller?.handleDrop(from: sender.draggingPasteboard, at: location) ?? false
    }

    func beginDrag(of urls: [URL], event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let draggingItems = urls.enumerated().map { index, url -> NSDraggingItem in
            let draggingItem = NSDraggingItem(pasteboardWriter: url as NSURL)
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            let offset = CGFloat(index) * 6
            draggingItem.setDraggingFrame(
                NSRect(
                    x: point.x - 21 + offset, y: point.y - 21 - offset, width: 42, height: 42),
                contents: icon)
            return draggingItem
        }
        beginDraggingSession(with: draggingItems, event: event, source: self)
    }
}

extension ShelfDropCatcherView: NSDraggingSource {
    func draggingSession(
        _ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        .copy
    }

    func draggingSession(
        _ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation
    ) {
        controller?.externalDragEnded(at: screenPoint, operation: operation)
    }
}
