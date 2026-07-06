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
    @Published private(set) var isOptionHeld = false
    @Published private(set) var livePositions: [UUID: CGPoint] = [:]
    @Published private(set) var selectedIDs: Set<UUID> = []

    private let store = ShelfStore()
    private var panels: [CGDirectDisplayID: NSPanel] = [:]
    private var collapsedSizes: [CGDirectDisplayID: CGSize] = [:]
    private var builtinDisplayID: CGDirectDisplayID?
    private var expandedSize = NotchGeometry.expandedSize

    private var screenObserver: NSObjectProtocol?
    private var dragMonitor: Any?
    private var flagsMonitors: [Any] = []
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
        if let monitor = NSEvent.addGlobalMonitorForEvents(
            matching: .flagsChanged,
            handler: {
                [weak self] event in
                let held = event.modifierFlags.contains(.option)
                Task { @MainActor in self?.isOptionHeld = held }
            })
        {
            flagsMonitors.append(monitor)
        }
        if let monitor = NSEvent.addLocalMonitorForEvents(
            matching: .flagsChanged,
            handler: {
                [weak self] event in
                let held = event.modifierFlags.contains(.option)
                Task { @MainActor in self?.isOptionHeld = held }
                return event
            })
        {
            flagsMonitors.append(monitor)
        }
    }

    func shutdown() {
        if let dragMonitor { NSEvent.removeMonitor(dragMonitor) }
        dragMonitor = nil
        for monitor in flagsMonitors { NSEvent.removeMonitor(monitor) }
        flagsMonitors.removeAll()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        collapseWorkItem?.cancel()
        collapseWorkItem = nil
        for panel in panels.values { panel.orderOut(nil) }
        panels.removeAll()
        collapsedSizes.removeAll()
    }

    private func flag(_ key: String, default def: Bool) -> Bool {
        SharedDefaults.store.object(forKey: key) as? Bool ?? def
    }
    private var openOnDrag: Bool { flag("notchShelfOpenOnDrag", default: true) }
    private var openOnHover: Bool { flag("notchShelfOpenOnHover", default: true) }
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
        let size = isExpanded ? expandedSize : (collapsedSizes[id] ?? NotchGeometry.fallbackSize)
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
        purgeExpired()
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
        selectedIDs = []
        updateAllFrames(animated: true)
    }

    func refreshOptionState() {
        let held = NSEvent.modifierFlags.contains(.option)
        if held != isOptionHeld { isOptionHeld = held }
    }

    func hoverChanged(_ hovering: Bool) {
        if hovering {
            guard openOnHover, optionSatisfied() else { return }
            expand()
        } else {
            collapseAfterDelay()
        }
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
            expand()
        default:
            break
        }
    }

    func resizeExpanded(toPointer point: CGPoint, resizesWidth: Bool, resizesHeight: Bool) {
        guard isExpanded else { return }
        let screen =
            NSScreen.screens.first { $0.frame.contains(point) }
            ?? NSScreen.screens.first { $0.displayID == builtinDisplayID }
        guard let screen else { return }
        let proposed = CGSize(
            width: resizesWidth
                ? abs(point.x - screen.frame.midX) * 2 + 8 : expandedSize.width,
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
