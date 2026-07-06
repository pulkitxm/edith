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
    private var pendingDragOutID: UUID?

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
    private var removeAfterDragOut: Bool { flag("notchShelfRemoveAfterDragOut", default: false) }
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
        guard isExpanded else { return }
        isExpanded = false
        updateAllFrames(animated: true)
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
        case .leftMouseDragged:
            let count = NSPasteboard(name: .drag).changeCount
            guard count != lastDragChangeCount else { return }
            lastDragChangeCount = count
            guard optionSatisfied(), isNearNotch(NSEvent.mouseLocation) else { return }
            expand()
        case .leftMouseUp:
            resolvePendingDragOut(at: NSEvent.mouseLocation)
        default:
            break
        }
    }

    private func resolvePendingDragOut(at point: CGPoint) {
        guard let id = pendingDragOutID else { return }
        pendingDragOutID = nil
        let insideShelf = panels.values.contains { $0.frame.contains(point) }
        guard !insideShelf, let item = items.first(where: { $0.id == id }) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.remove(item)
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

    func open(_ item: ShelfItem) {
        NSWorkspace.shared.open(fileURL(for: item))
        collapseNow()
    }

    func reveal(_ item: ShelfItem) {
        NSWorkspace.shared.activateFileViewerSelecting([fileURL(for: item)])
        collapseNow()
    }

    func remove(_ item: ShelfItem) {
        store.remove(item)
        items = store.items
        collapseNow()
    }

    func dragOutProvider(for item: ShelfItem) -> NSItemProvider {
        let provider = NSItemProvider(contentsOf: fileURL(for: item)) ?? NSItemProvider()
        if removeAfterDragOut { pendingDragOutID = item.id }
        return provider
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
                receivePromise(receiver)
            case let url as URL:
                handled = true
                if let location, let existing = store.item(forFileURL: url) {
                    pendingDragOutID = nil
                    store.setPosition(location, for: existing)
                    items = store.items
                    repositioned = true
                } else {
                    addFile(at: url)
                }
            case let text as String:
                handled = true
                addText(text)
            default:
                break
            }
        }
        if handled, !repositioned { collapseAfterDelay(1.2) }
        return handled
    }

    private func receivePromise(_ receiver: NSFilePromiseReceiver) {
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
                self.store.adopt(fileAt: url, id: id)
                self.items = self.store.items
                self.fireHaptic()
            }
        }
    }

    private func addFile(at url: URL) {
        guard store.addCopy(of: url) != nil else { return }
        items = store.items
        fireHaptic()
    }

    private func addText(_ text: String) {
        guard store.addText(text) != nil else { return }
        items = store.items
        fireHaptic()
    }
}

@MainActor
private final class ShelfDropCatcherView: NSView {
    weak var controller: NotchShelfController?

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let windowPoint = convert(sender.draggingLocation, from: nil)
        let location = CGPoint(x: windowPoint.x, y: bounds.height - windowPoint.y)
        return controller?.handleDrop(from: sender.draggingPasteboard, at: location) ?? false
    }
}
