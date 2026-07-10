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
    @Published private(set) var isExpanded = false
    @Published private(set) var isResizing = false
    @Published private(set) var nowPlaying: NotchNowPlaying?
    @Published private(set) var nowPlayingArtwork: NSImage?
    @Published var activeTab: NotchTab = .home
    @Published private(set) var currentAlert: NotchAlert?
    weak var clipboardStore: ClipboardStore?
    private var alertDetectors: NotchAlertDetectors?
    private var alertWorkItem: DispatchWorkItem?
    private var alertPinned = false
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
    private var expandedSize = NotchGeometry.expandedSize

    private var screenObserver: NSObjectProtocol?
    private var dragMonitor: Any?
    private var moveMonitorGlobal: Any?
    private var moveMonitorLocal: Any?
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
        let width = SharedDefaults.store.double(forKey: "notchShelfExpandedWidth")
        let height = SharedDefaults.store.double(forKey: "notchShelfExpandedHeight")
        if width > 0, height > 0 {
            expandedSize = CGSize(
                width: max(width, NotchGeometry.expandedSize.width),
                height: max(height, NotchGeometry.expandedSize.height))
        }
        purgeExpired()
        rebuildPanels()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.rebuildPanels() }
        }
        dragMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        ) { [weak self] event in
            Task { @MainActor in self?.handleGlobalMouse(event) }
        }
        startAlertsIfEnabled()
    }

    private var alertsEnabled: Bool { flag("notchAlertsEnabled", default: true) }

    private func startAlertsIfEnabled() {
        guard alertsEnabled else { return }
        let detectors = NotchAlertDetectors { [weak self] alert in
            self?.postAlert(alert)
        }
        detectors.start()
        alertDetectors = detectors
    }

    func postAlert(_ alert: NotchAlert) {
        guard alertsEnabled, !isExpanded else { return }
        guard NotchAlertLogic.shouldPreempt(current: currentAlert, incoming: alert) else { return }
        currentAlert = alert
        alertPinned = false
        updateAllFrames(animated: true)
        scheduleAlertHide(after: alert.autoHide)
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
        updateAllFrames(animated: true)
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
    private var showOnExternal: Bool { flag("notchShelfShowOnExternal", default: false) }
    private var hapticsOn: Bool { flag("notchShelfHaptics", default: true) }
    private var keepDuration: ShelfKeepDuration {
        ShelfKeepDuration(
            rawValue: SharedDefaults.store.string(forKey: "notchShelfKeepDuration") ?? "")
            ?? .forever
    }

    private func rebuildPanels() {
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
    }

    private func placePanel(on screen: NSScreen, id: CGDirectDisplayID) {
        collapsedSizes[id] = NotchGeometry.collapsedSize(
            screenWidth: screen.frame.width,
            leftAreaWidth: screen.auxiliaryTopLeftArea?.width,
            rightAreaWidth: screen.auxiliaryTopRightArea?.width,
            safeAreaTop: screen.safeAreaInsets.top)
        let panel = panels[id] ?? makePanel(id: id)
        applyFrame(panel, screen: screen, id: id, animated: false)
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
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 8)
        panel.collectionBehavior = [
            .fullScreenAuxiliary, .stationary, .canJoinAllSpaces, .ignoresCycle,
        ]

        let container = ShelfDropCatcherView()
        container.controller = self
        container.registerForDraggedTypes(Self.acceptedDraggedTypes)

        let host = NSHostingView(rootView: AnyView(NotchShelfContentView(controller: self)))
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

    private func applyFrame(
        _ panel: NSPanel, screen: NSScreen, id: CGDirectDisplayID, animated: Bool
    ) {
        let base = collapsedSizes[id] ?? NotchGeometry.fallbackSize
        let size: CGSize
        if isExpanded {
            size = expandedSize
        } else if currentAlert != nil, id == builtinDisplayID {
            size = NotchGeometry.alertDropSize
        } else {
            size = NotchGeometry.collapsedSize(base: base, hasLiveActivity: nowPlaying != nil)
        }
        let frame = NSRect(
            origin: NotchGeometry.origin(screenFrame: screen.frame, panelSize: size), size: size)
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.35
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.34, 1.4, 0.64, 1)
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }
    }

    private func updateAllFrames(animated: Bool) {
        for screen in NSScreen.screens {
            guard let id = screen.displayID, let panel = panels[id] else { continue }
            applyFrame(panel, screen: screen, id: id, animated: animated)
        }
    }

    private func optionSatisfied() -> Bool {
        !requireOption || NSEvent.modifierFlags.contains(.option)
    }

    func expand() {
        collapseWorkItem?.cancel()
        gateWorkItem?.cancel()
        gateWorkItem = nil
        purgeExpired()
        if currentAlert != nil {
            currentAlert = nil
            alertWorkItem?.cancel()
            alertWorkItem = nil
        }
        gate.forceOpen()
        startMoveMonitor()
        guard !isExpanded else { return }
        isExpanded = true
        updateAllFrames(animated: true)
        fireHaptic()
    }

    func collapseAfterDelay(_ delay: TimeInterval = 0.35) {
        collapseWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.collapseNow() }
        collapseWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func collapseNow() {
        guard isExpanded, !isSharing else { return }
        isExpanded = false
        isResizing = false
        selectedIDs = []
        gate.forceClosed()
        gateWorkItem?.cancel()
        gateWorkItem = nil
        stopMoveMonitor()
        updateAllFrames(animated: true)
    }

    func hoverChanged(_ hovering: Bool) {
        guard !isExpanded else { return }
        applyProximity(hovering ? .open : .outside)
    }

    private func monotonicNow() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

    private func applyProximity(_ raw: NotchProximity) {
        var proximity = raw
        if !gate.isOpen, proximity == .open, !(openOnHover && optionSatisfied()) {
            proximity = .outside
        }
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
            expand()
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
        guard isExpanded, let frames = builtinFrames() else { return }
        applyProximity(
            NotchGeometry.proximity(
                point: NSEvent.mouseLocation, collapsedFrame: frames.collapsed,
                expandedFrame: frames.expanded))
    }

    private func builtinFrames() -> (collapsed: CGRect, expanded: CGRect)? {
        guard let id = builtinDisplayID,
            let screen = NSScreen.screens.first(where: { $0.displayID == id })
        else { return nil }
        let collapsedSize = NotchGeometry.collapsedSize(
            base: collapsedSizes[id] ?? NotchGeometry.fallbackSize,
            hasLiveActivity: nowPlaying != nil)
        let collapsed = CGRect(
            origin: NotchGeometry.origin(screenFrame: screen.frame, panelSize: collapsedSize),
            size: collapsedSize)
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
        guard openOnDrag else { return }
        switch event.type {
        case .leftMouseDown:
            lastDragChangeCount = NSPasteboard(name: .drag).changeCount
            internalDragItemIDs = []
        case .leftMouseDragged:
            guard NSPasteboard(name: .drag).changeCount != lastDragChangeCount else { return }
            guard optionSatisfied(), isNearNotch(NSEvent.mouseLocation) else { return }
            activeTab = .files
            expand()
        default:
            break
        }
    }

    func resizeExpanded(toPointer point: CGPoint, resizesWidth: Bool, resizesHeight: Bool) {
        guard isExpanded else { return }
        collapseWorkItem?.cancel()
        gateWorkItem?.cancel()
        gateWorkItem = nil
        gate.forceOpen()
        isResizing = true
        let screen =
            NSScreen.screens.first { $0.frame.contains(point) }
            ?? NSScreen.screens.first { $0.displayID == builtinDisplayID }
        guard let screen else { return }
        let proposed = CGSize(
            width: resizesWidth
                ? abs(point.x - screen.frame.midX) * 2 + 2 * NotchGeometry.expandedTopRadius
                : expandedSize.width,
            height: resizesHeight ? screen.frame.maxY - point.y + 4 : expandedSize.height)
        let minSize = NotchGeometry.expandedSize
        let size = CGSize(
            width: min(max(proposed.width, minSize.width), screen.frame.width * 0.9),
            height: min(max(proposed.height, minSize.height), screen.frame.height * 0.7))
        guard size != expandedSize else { return }
        expandedSize = size
        SharedDefaults.store.set(Double(size.width), forKey: "notchShelfExpandedWidth")
        SharedDefaults.store.set(Double(size.height), forKey: "notchShelfExpandedHeight")
        updateAllFrames(animated: false)
    }

    func endResize() {
        isResizing = false
    }

    private func isNearNotch(_ point: CGPoint) -> Bool {
        guard let id = builtinDisplayID, let panel = panels[id] else { return false }
        return panel.frame.insetBy(dx: -40, dy: -20).contains(point)
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
            external: external.current)
        let active = resolved?.isPlaying == true ? resolved : nil
        guard active != nowPlaying else { return }
        let hadActivity = nowPlaying != nil
        let trackChanged =
            active?.title != nowPlaying?.title || active?.source != nowPlaying?.source
        nowPlaying = active
        if trackChanged { loadArtwork(for: active) }
        if (active != nil) != hadActivity, !isExpanded {
            updateAllFrames(animated: true)
        }
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
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID)
        else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    func attachClipboard(_ store: ClipboardStore?) {
        clipboardStore = store
    }

    func selectTab(_ tab: NotchTab) {
        activeTab = tab
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
        guard let text = entry.preview else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
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
        let insideShelf = panels.values.contains { $0.frame.contains(point) }
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
        var repositioned = false
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
                    repositioned = true
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
        if handled, !repositioned { collapseAfterDelay(1.2) }
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
final class ShelfDropCatcherView: NSView {
    weak var controller: NotchShelfController?

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let windowPoint = convert(sender.draggingLocation, from: nil)
        let location = CGPoint(x: windowPoint.x, y: bounds.height - windowPoint.y)
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
