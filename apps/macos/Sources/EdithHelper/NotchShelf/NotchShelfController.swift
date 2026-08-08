import AppKit
import Combine
import EdithKit
import SwiftUI

extension NSScreen {
    fileprivate var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}

@MainActor
final class NotchShelfController: ObservableObject, FeatureModule {
    @Published private(set) var items: [ShelfItem] = []
    @Published private(set) var expandedDisplay: CGDirectDisplayID?
    @Published private(set) var hoverDisplay: CGDirectDisplayID?
    @Published private(set) var nowPlaying: NotchNowPlaying?
    @Published private(set) var nowPlayingArtwork: NSImage?
    @Published var activeTab: NotchTab = .home
    @Published private(set) var currentAlert: NotchAlert?
    weak var clipboardStore: ClipboardStore?
    private weak var colorPickerStore: ColorPickerStore?
    @Published private(set) var canPickColor = false
    @Published private(set) var usageStore: UsageStore?
    @Published private(set) var calendarStore: CalendarStore?
    private var externalVolume: Double = 0.7
    private var alertDetectors: NotchAlertDetectors?
    private var alertWorkItem: DispatchWorkItem?
    private var alertPinned = false
    private var pendingAlerts: [PendingNotchAlert] = []
    @Published private(set) var livePositions: [UUID: CGPoint] = [:]
    @Published private(set) var selectedIDs: Set<UUID> = []

    let external = ExternalMusic()
    private weak var localMusic: MusicPlayer?
    private var externalCancellable: AnyCancellable?
    private var localCancellable: AnyCancellable?
    private var artworkTask: Task<Void, Never>?

    private let store = ShelfStore()
    private var panels: [CGDirectDisplayID: NSPanel] = [:]
    private var collapsedSizes: [CGDirectDisplayID: CGSize] = [:]
    private var builtinDisplayID: CGDirectDisplayID?
    private var fullScreenDisplays: Set<CGDirectDisplayID> = []

    private var screenObserver: NSObjectProtocol?
    private var spaceObserver: NSObjectProtocol?
    private var dragMonitor: Any?
    private var moveMonitorGlobal: Any?
    private var moveMonitorLocal: Any?
    private var gateDisplay: CGDirectDisplayID?
    private var gate = NotchHoverGate(
        openDwell: NotchShelfController.openDwell, closeGrace: NotchShelfController.closeGrace)
    private var gateWorkItem: DispatchWorkItem?
    static let openDwell: TimeInterval = 0.1
    static let closeGrace: TimeInterval = 0.4
    private var lastDragChangeCount = -1
    private var collapseWorkItem: DispatchWorkItem?
    private var pendingDragOutIDs: Set<UUID> = []
    private var internalDragItemIDs: Set<UUID> = []
    private var sharePickerDelegate: SharePickerDelegate?
    private var isSharing = false
    private var dragStartPositions: [UUID: CGPoint] = [:]
    private var dragPointerStart: CGPoint?

    init() {
        items = store.items
        store.onExternalChange = { [weak self] in
            guard let self else { return }
            self.items = self.store.items
        }
        purgeExpired()
        rebuildPanels()
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
        dragMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        ) { [weak self] event in
            Task { @MainActor in self?.handleGlobalMouse(event) }
        }
        startMoveMonitor()
        startAlertsIfEnabled()
    }

    private var alertsEnabled: Bool { flag("notchAlertsEnabled", default: true) }

    private func startAlertsIfEnabled() {
        guard alertsEnabled, alertDetectors == nil else { return }
        let detectors = NotchAlertDetectors { [weak self] alert in
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
        guard let tab = alert.settingsTab else { return }
        MainApp.openSettings(tab: tab)
    }

    func dismissAlert() {
        alertPinned = false
        hideAlert()
    }

    func shutdown() {
        if let dragMonitor { NSEvent.removeMonitor(dragMonitor) }
        dragMonitor = nil
        stopMoveMonitor()
        alertDetectors?.stop()
        alertDetectors = nil
        alertWorkItem?.cancel()
        alertWorkItem = nil
        external.stop()
        externalCancellable = nil
        localCancellable = nil
        artworkTask?.cancel()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        if let spaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver)
        }
        spaceObserver = nil
        collapseWorkItem?.cancel()
        collapseWorkItem = nil
        gateWorkItem?.cancel()
        gateWorkItem = nil
        for panel in panels.values { panel.orderOut(nil) }
        panels.removeAll()
        collapsedSizes.removeAll()
    }

    private func flag(_ key: String, default def: Bool) -> Bool {
        SharedDefaults.store.object(forKey: key) as? Bool ?? def
    }
    private var openOnDrag: Bool { flag("notchShelfOpenOnDrag", default: true) }
    private var openOnHover: Bool { flag("notchShelfOpenOnHover", default: true) }
    private var showMusic: Bool { flag("notchShelfShowMusic", default: true) }
    private var requireOption: Bool { flag("notchShelfRequireOption", default: false) }
    private var removeAfterDragOut: Bool { flag("notchShelfRemoveAfterDragOut", default: true) }
    private var showOnExternal: Bool { flag("notchShelfShowOnExternal", default: true) }
    private var hapticsOn: Bool { flag("notchShelfHaptics", default: true) }
    private var keepDuration: ShelfKeepDuration {
        ShelfKeepDuration(
            rawValue: SharedDefaults.store.string(forKey: "notchShelfKeepDuration") ?? "")
            ?? .forever
    }

    func rebuildPanels() {
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
        updateFullScreenVisibility()
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
            guard let id = screen.displayID, let panel = panels[id] else { continue }
            let fullScreen = isFullScreenSpace(screen)
            if fullScreen {
                fullScreenDisplays.insert(id)
                if expandedDisplay == id { collapseNow() }
            } else {
                fullScreenDisplays.remove(id)
            }
            panel.alphaValue = fullScreen ? 0 : 1
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
        let panel = NSPanel(
            contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
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
        panel.orderFrontRegardless()
        return panel
    }

    private static let acceptedDraggedTypes: [NSPasteboard.PasteboardType] = {
        var types: [NSPasteboard.PasteboardType] = [.fileURL, .string]
        types += NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
        return types
    }()

    private func shapeSize(
        for id: CGDirectDisplayID, expanded: Bool, alert: NotchAlert?, music: Bool
    ) -> CGSize {
        let base = collapsedSizes[id] ?? NotchGeometry.fallbackSize
        if expanded {
            return NotchGeometry.expandedShapeSize(
                tab: activeTab, hasMusic: music, notchHeight: base.height)
        }
        if alert != nil, id == builtinDisplayID { return NotchGeometry.alertDropSize }
        return NotchGeometry.collapsedSize(base: base, hasLiveActivity: music)
    }

    private func targetShapeSize(for id: CGDirectDisplayID) -> CGSize {
        shapeSize(
            for: id, expanded: expandedDisplay == id, alert: currentAlert,
            music: nowPlaying != nil)
    }

    private func applyExactFrame(_ panel: NSPanel, screen: NSScreen, id: CGDirectDisplayID) {
        let size = NotchGeometry.panelSize(forShape: NotchGeometry.expandedMaxSize)
        panel.setFrame(
            NSRect(
                origin: NotchGeometry.origin(screenFrame: screen.frame, panelSize: size),
                size: size),
            display: true)
    }

    private func syncFrames() {
        for screen in NSScreen.screens {
            guard let id = screen.displayID, let panel = panels[id] else { continue }
            updateInteractiveShape(panel, id: id)
        }
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
                allowMouse = true
            } else if currentAlert != nil, id == builtinDisplayID {
                allowMouse = shapeFrame(of: panel).contains(cursor)
            } else {
                allowMouse = false
            }
            panel.ignoresMouseEvents = fullScreenDisplays.contains(id) || !allowMouse
        }
    }

    private func optionSatisfied() -> Bool {
        !requireOption || NSEvent.modifierFlags.contains(.option)
    }

    var isExpanded: Bool { expandedDisplay != nil }

    func isExpanded(on id: CGDirectDisplayID) -> Bool { expandedDisplay == id }

    func isHovering(on id: CGDirectDisplayID) -> Bool { hoverDisplay == id }

    func expand(on id: CGDirectDisplayID) {
        collapseWorkItem?.cancel()
        gateWorkItem?.cancel()
        gateWorkItem = nil
        purgeExpired()
        alertWorkItem?.cancel()
        alertWorkItem = nil
        gate.forceOpen()
        gateDisplay = id
        guard expandedDisplay != id else { return }
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
        switch gate.fire(now: monotonicNow()) {
        case .opened:
            if let gateDisplay { expand(on: gateDisplay) }
        case .closed:
            if isSharing {
                gate.forceOpen()
            } else {
                collapseNow()
            }
        case .none, .schedule, .cancelPending:
            break
        }
    }

    private func handleMouseMoved() {
        refreshMouseTransparency()
        let point = NSEvent.mouseLocation
        if let expandedDisplay, let frames = frames(for: expandedDisplay) {
            applyProximity(
                NotchGeometry.proximity(
                    point: point, collapsedFrame: frames.collapsed,
                    expandedFrame: frames.expanded),
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
            hasLiveActivity: nowPlaying != nil)
        let collapsed = CGRect(
            origin: NotchGeometry.origin(screenFrame: screen.frame, panelSize: collapsedSize),
            size: collapsedSize)
        let expandedSize = shapeSize(
            for: id, expanded: true, alert: nil, music: nowPlaying != nil)
        let expanded = CGRect(
            origin: NotchGeometry.origin(screenFrame: screen.frame, panelSize: expandedSize),
            size: expandedSize)
        return (collapsed, expanded)
    }

    private func startMoveMonitor() {
        guard moveMonitorGlobal == nil else { return }
        moveMonitorGlobal = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) {
            [weak self] _ in
            Task { @MainActor in self?.handleMouseMoved() }
        }
        moveMonitorLocal = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) {
            [weak self] event in
            Task { @MainActor in self?.handleMouseMoved() }
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
            guard NSPasteboard(name: .drag).changeCount != lastDragChangeCount else { return }
            let point = NSEvent.mouseLocation
            guard optionSatisfied(), let id = notchDisplay(near: point), isNearNotch(point, on: id)
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
        items = store.items
    }

    private func fireHaptic() {
        guard hapticsOn else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
    }

    func attachLocalMusic(_ player: MusicPlayer?) {
        if showMusic {
            external.start()
            if externalCancellable == nil {
                externalCancellable = external.objectWillChange.sink { [weak self] in
                    Task { @MainActor in self?.recomputeNowPlaying() }
                }
            }
            localMusic = player
            localCancellable = player?.objectWillChange.sink { [weak self] in
                Task { @MainActor in self?.recomputeNowPlaying() }
            }
        } else {
            external.stop()
            externalCancellable = nil
            localMusic = nil
            localCancellable = nil
        }
        recomputeNowPlaying()
    }

    private func recomputeNowPlaying() {
        let resolved = NotchMusicResolver.resolve(
            localTitle: localMusic?.current?.title,
            localPlaying: localMusic?.isPlaying ?? false,
            external: external.current,
            previous: nowPlaying)
        let active = resolved
        guard active != nowPlaying else { return }
        let hadActivity = nowPlaying != nil
        let trackChanged =
            active?.title != nowPlaying?.title || active?.source != nowPlaying?.source
        nowPlaying = active
        if trackChanged { loadArtwork(for: active) }
        if (active != nil) != hadActivity, !isExpanded { syncFrames() }
    }

    private func loadArtwork(for track: NotchNowPlaying?) {
        artworkTask?.cancel()
        guard let track else {
            nowPlayingArtwork = nil
            return
        }
        switch track.source {
        case .external(let app):
            nowPlayingArtwork = Self.appIcon(for: app)
        case .local:
            nowPlayingArtwork = nil
            guard let player = localMusic, let current = player.current else { return }
            artworkTask = Task { [weak self] in
                let image = await player.artwork(for: current)
                await MainActor.run {
                    guard !Task.isCancelled else { return }
                    self?.nowPlayingArtwork = image
                }
            }
        }
    }

    private static func appIcon(for app: ExternalApp) -> NSImage? {
        if let running = NSRunningApplication.runningApplications(
            withBundleIdentifier: app.bundleID
        ).first, let icon = running.icon {
            return icon
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID)
        else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    func attachClipboard(_ store: ClipboardStore?) {
        clipboardStore = store
        if store == nil, activeTab == .clipboard {
            activeTab = .home
            if isExpanded { syncFrames() }
        }
    }

    func attachUsage(_ store: UsageStore?) {
        usageStore = store
    }

    func attachCalendar(_ store: CalendarStore?) {
        calendarStore = store
    }

    var nowPlayingSeekable: Bool {
        if case .local = nowPlaying?.source { return true }
        return false
    }

    func nowPlayingProgress() -> Double {
        nowPlayingSeekable ? (localMusic?.progressNow() ?? 0) : 0
    }

    func nowPlayingSeek(_ fraction: Double) {
        guard nowPlayingSeekable else { return }
        localMusic?.seek(to: fraction)
    }

    var nowPlayingVolume: Double {
        switch nowPlaying?.source {
        case .local: return localMusic?.volume ?? 0
        case .external: return externalVolume
        case .none: return 0
        }
    }

    func setNowPlayingVolume(_ value: Double) {
        switch nowPlaying?.source {
        case .local: localMusic?.volume = value
        case .external:
            externalVolume = value
            external.setVolume(Float(value))
        case .none: break
        }
    }

    func selectTab(_ tab: NotchTab) {
        activeTab = tab
        if isExpanded { syncFrames() }
    }

    func attachColorPicker(_ store: ColorPickerStore?) {
        colorPickerStore = store
        canPickColor = store != nil
    }

    func cleanKeyboard() {
        collapseNow()
        IPC.post(IPC.Name.requestKeyboardClean)
    }

    func pickColor() {
        collapseNow()
        colorPickerStore?.pick()
    }

    func openNowPlayingApp() {
        let source = nowPlaying?.source
        collapseNow()
        switch source {
        case .external(let app):
            guard
                let url = NSWorkspace.shared.urlForApplication(
                    withBundleIdentifier: app.bundleID)
            else { return }
            NSWorkspace.shared.openApplication(
                at: url, configuration: NSWorkspace.OpenConfiguration())
        case .local:
            MainApp.openDashboard()
        case .none:
            break
        }
    }

    func openNowPlayingLocation() {
        guard case .local = nowPlaying?.source, let track = localMusic?.current else {
            openNowPlayingApp()
            return
        }
        collapseNow()
        MusicReveal.request(trackPath: track.relativePath)
    }

    func nowPlayingPlayPause() {
        switch nowPlaying?.source {
        case .local: localMusic?.playPause()
        case .external: external.playPause()
        case .none: break
        }
    }

    func nowPlayingNext() {
        switch nowPlaying?.source {
        case .local: localMusic?.next()
        case .external: external.next()
        case .none: break
        }
    }

    func nowPlayingPrevious() {
        switch nowPlaying?.source {
        case .local: localMusic?.previous()
        case .external: external.previous()
        case .none: break
        }
    }

    func copyClipboardEntry(_ entry: ClipboardEntry) {
        if let store = clipboardStore {
            store.activate(entry)
        } else if let text = entry.preview {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
        collapseNow()
    }

    func fileURL(for item: ShelfItem) -> URL { store.fileURL(for: item) }

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
        for member in group(for: item) {
            NSWorkspace.shared.open(fileURL(for: member))
        }
        collapseNow()
    }

    func reveal(_ item: ShelfItem) {
        NSWorkspace.shared.activateFileViewerSelecting(group(for: item).map { fileURL(for: $0) })
        collapseNow()
    }

    private func removeSingle(_ item: ShelfItem) {
        store.remove(item)
        selectedIDs.remove(item.id)
        items = store.items
    }

    func remove(_ item: ShelfItem) {
        for member in group(for: item) { removeSingle(member) }
        collapseNow()
    }

    func share(_ item: ShelfItem) {
        let mouse = NSEvent.mouseLocation
        let panel =
            panels.values.first { $0.frame.contains(mouse) }
            ?? builtinDisplayID.flatMap { panels[$0] }
        guard let panel, let view = panel.contentView else { return }
        isSharing = true
        collapseWorkItem?.cancel()
        let delegate = SharePickerDelegate { [weak self] in
            self?.isSharing = false
            self?.sharePickerDelegate = nil
            self?.collapseAfterDelay()
        }
        sharePickerDelegate = delegate
        let picker = NSSharingServicePicker(items: group(for: item).map { fileURL(for: $0) })
        picker.delegate = delegate
        let size = view.bounds.size
        let index = items.firstIndex(where: { $0.id == item.id }) ?? 0
        let position = NotchGeometry.itemPosition(stored: item.position, index: index, in: size)
        let anchor = NSRect(
            x: position.x - 20, y: size.height - position.y - 20, width: 40, height: 40)
        picker.show(relativeTo: anchor, of: view, preferredEdge: .minY)
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
        for (id, point) in livePositions {
            guard let member = items.first(where: { $0.id == id }) else { continue }
            store.setPosition(point, for: member)
        }
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
        internalDragItemIDs = Set(members.map(\.id))
        if removeAfterDragOut { pendingDragOutIDs = Set(members.map(\.id)) }
        catcher.beginDrag(of: members.map { fileURL(for: $0) }, event: event)
    }

    func externalDragEnded(at point: CGPoint, operation: NSDragOperation) {
        internalDragItemIDs = []
        guard !pendingDragOutIDs.isEmpty else { return }
        let ids = pendingDragOutIDs
        pendingDragOutIDs = []
        let insideShelf = panels.values.contains { shapeFrame(of: $0).contains(point) }
        guard !insideShelf, operation != [] else { return }
        let members = items.filter { ids.contains($0.id) }
        guard !members.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            for member in members { self?.removeSingle(member) }
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
        let destination = store.promiseDestination(id: id)
        receiver.receivePromisedFiles(
            atDestination: destination, options: [:], operationQueue: .main
        ) {
            [weak self] url, error in
            Task { @MainActor in
                guard let self else { return }
                guard error == nil else {
                    self.store.discardPromiseDestination(id: id)
                    return
                }
                if let item = self.store.adopt(fileAt: url, id: id), let location {
                    self.store.setPosition(location, for: item)
                }
                self.items = self.store.items
                self.fireHaptic()
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
