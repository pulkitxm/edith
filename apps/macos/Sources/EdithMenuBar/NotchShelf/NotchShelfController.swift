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

    private let store = ShelfStore()
    private var panels: [CGDirectDisplayID: NSPanel] = [:]
    private var collapsedSizes: [CGDirectDisplayID: CGSize] = [:]
    private var builtinDisplayID: CGDirectDisplayID?

    private var screenObserver: NSObjectProtocol?
    private var dragMonitor: Any?
    private var lastDragChangeCount = -1
    private var collapseWorkItem: DispatchWorkItem?

    init() {
        items = store.items
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
    }

    func shutdown() {
        if let dragMonitor { NSEvent.removeMonitor(dragMonitor) }
        dragMonitor = nil
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
        let size =
            isExpanded
            ? NotchGeometry.expandedSize : (collapsedSizes[id] ?? NotchGeometry.fallbackSize)
        let frame = NSRect(
            origin: NotchGeometry.origin(screenFrame: screen.frame, panelSize: size), size: size)
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.22
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
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
        default:
            break
        }
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
    }

    func reveal(_ item: ShelfItem) {
        NSWorkspace.shared.activateFileViewerSelecting([fileURL(for: item)])
    }

    func remove(_ item: ShelfItem) {
        store.remove(item)
        items = store.items
    }

    func dragOutProvider(for item: ShelfItem) -> NSItemProvider {
        let provider = NSItemProvider(contentsOf: fileURL(for: item)) ?? NSItemProvider()
        if removeAfterDragOut {
            DispatchQueue.main.async { [weak self] in self?.remove(item) }
        }
        return provider
    }

    @discardableResult
    func handleDrop(from pasteboard: NSPasteboard) -> Bool {
        let objects =
            pasteboard.readObjects(
                forClasses: [NSFilePromiseReceiver.self, NSURL.self, NSString.self],
                options: [.urlReadingFileURLsOnly: true]) ?? []
        var handled = false
        for object in objects {
            switch object {
            case let receiver as NSFilePromiseReceiver:
                handled = true
                receivePromise(receiver)
            case let url as URL:
                handled = true
                addFile(at: url)
            case let text as String:
                handled = true
                addText(text)
            default:
                break
            }
        }
        if handled { collapseAfterDelay(1.2) }
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
        controller?.handleDrop(from: sender.draggingPasteboard) ?? false
    }
}
