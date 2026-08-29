import AppKit
import ApplicationServices
import CoreGraphics
import EdithKit
import SwiftUI

private struct DockToolsRuntimeWindow {
    let value: DockToolsWindow
    let element: AXUIElement
}

private struct DockToolsHit {
    let application: NSRunningApplication
    let iconFrame: CGRect
}

private struct DockToolsGreenTarget {
    let window: AXUIElement
    let frame: CGRect
    let identifier: String
}

private func dockToolsEventCallback(
    _: CGEventTapProxy, type: CGEventType, event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let engine = Unmanaged<DockToolsEngine>.fromOpaque(userInfo).takeUnretainedValue()
    return MainActor.assumeIsolated {
        engine.handle(type: type, event: event)
    }
}

private func dockToolsAXCallback(
    _: AXObserver, element: AXUIElement, notification: CFString,
    userInfo: UnsafeMutableRawPointer?
) {
    guard let userInfo else { return }
    let monitor = Unmanaged<DockToolsAutoQuitMonitor>.fromOpaque(userInfo).takeUnretainedValue()
    MainActor.assumeIsolated {
        monitor.handle(element: element, notification: notification as String)
    }
}

@MainActor
final class DockToolsEngine {
    private(set) var preferences = DockToolsPreferences()
    private let preview = DockToolsPreviewController()
    private lazy var autoQuit = DockToolsAutoQuitMonitor()
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var pendingHover: DispatchWorkItem?
    private var pendingHide: DispatchWorkItem?
    private var pendingApplicationPID: pid_t?
    private var swallowedMouseUp = false
    private var greenTarget: DockToolsGreenTarget?
    private var restoredFrames: [String: CGRect] = [:]
    private var dockPID: pid_t?
    private var lastMoveAt = CFAbsoluteTime(0)

    init() {
        syncSettings()
    }

    func syncSettings() {
        preferences = DockToolsPreferences()
        autoQuit.sync(enabled: preferences.enabled && preferences.quitOnLastWindow)
        guard preferences.enabled, AXIsProcessTrusted() else {
            stopEventTap()
            preview.close()
            return
        }
        startEventTap()
    }

    func shutdown() {
        pendingHover?.cancel()
        pendingHide?.cancel()
        stopEventTap()
        preview.shutdown()
        autoQuit.shutdown()
    }

    func perform(_ info: [AnyHashable: Any]) {
        let requestID = info[DockToolsIPC.requestIDKey] as? String ?? ""
        let operation = info[DockToolsIPC.operationKey] as? String ?? ""
        let bundleIdentifier = info[DockToolsIPC.bundleIdentifierKey] as? String
        var status = "ok"
        var payload = ""
        switch operation {
        case "status":
            payload = DockToolsIPC.encode(runtimeStatus())
        case "windows":
            guard AXIsProcessTrusted() else {
                status = "notAuthorized"
                break
            }
            guard let application = application(bundleIdentifier: bundleIdentifier) else {
                status = "notFound"
                break
            }
            payload = DockToolsIPC.encode(windows(for: application).map(\.value))
        case "show":
            guard AXIsProcessTrusted() else {
                status = "notAuthorized"
                break
            }
            guard let application = application(bundleIdentifier: bundleIdentifier),
                !preferences.excludes(application.bundleIdentifier)
            else {
                status = "notFound"
                break
            }
            showPreview(for: application, iconFrame: nil)
        default:
            status = "invalid"
        }
        IPC.post(
            IPC.Name.dockToolsOperationResult,
            userInfo: [
                DockToolsIPC.requestIDKey: requestID,
                DockToolsIPC.statusKey: status,
                DockToolsIPC.payloadKey: payload,
            ])
    }

    func runtimeStatus() -> DockToolsStatus {
        DockToolsStatus(
            preferences: preferences, helperRunning: true,
            accessibilityGranted: AXIsProcessTrusted(),
            screenRecordingGranted: CGPreflightScreenCaptureAccess())
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        switch type {
        case .mouseMoved:
            handleMouseMove(event.location)
        case .leftMouseDown:
            if handleMouseDown(event) { return nil }
        case .leftMouseUp:
            if swallowedMouseUp {
                swallowedMouseUp = false
                greenTarget = nil
                return nil
            }
        default:
            break
        }
        return Unmanaged.passUnretained(event)
    }

    private func startEventTap() {
        guard eventTap == nil else { return }
        let mask =
            CGEventMask(1 << CGEventType.mouseMoved.rawValue)
            | CGEventMask(1 << CGEventType.leftMouseDown.rawValue)
            | CGEventMask(1 << CGEventType.leftMouseUp.rawValue)
        let info = Unmanaged.passUnretained(self).toOpaque()
        guard
            let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap, place: .headInsertEventTap,
                options: .defaultTap, eventsOfInterest: mask,
                callback: dockToolsEventCallback, userInfo: info)
        else { return }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        eventTap = tap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func stopEventTap() {
        guard let eventTap else { return }
        CGEvent.tapEnable(tap: eventTap, enable: false)
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        self.eventTap = nil
        runLoopSource = nil
    }

    private func handleMouseMove(_ point: CGPoint) {
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastMoveAt >= 1.0 / 45 else { return }
        lastMoveAt = now
        guard preferences.previewMode == .hover else { return }
        if preview.contains(axPoint: point) {
            cancelHide()
            return
        }
        guard let hit = dockHit(at: point), !preferences.excludes(hit.application.bundleIdentifier)
        else {
            pendingHover?.cancel()
            pendingHover = nil
            pendingApplicationPID = nil
            scheduleHide()
            return
        }
        cancelHide()
        if preview.applicationPID == hit.application.processIdentifier { return }
        if pendingApplicationPID == hit.application.processIdentifier { return }
        pendingHover?.cancel()
        pendingApplicationPID = hit.application.processIdentifier
        let work = DispatchWorkItem { [weak self, weak application = hit.application] in
            guard let self, let application,
                self.pendingApplicationPID == application.processIdentifier
            else { return }
            self.pendingApplicationPID = nil
            self.showPreview(for: application, iconFrame: hit.iconFrame)
        }
        pendingHover = work
        DispatchQueue.main.asyncAfter(deadline: .now() + preferences.hoverDelay, execute: work)
    }

    private func handleMouseDown(_ event: CGEvent) -> Bool {
        let point = event.location
        if preferences.greenButtonMaximizes, let target = greenTarget(at: point) {
            toggleMaximize(target)
            greenTarget = target
            swallowedMouseUp = true
            return true
        }
        guard let hit = dockHit(at: point), !preferences.excludes(hit.application.bundleIdentifier)
        else { return false }
        let option = event.flags.contains(.maskAlternate)
        if preferences.previewMode == .optionClick, option {
            showPreview(for: hit.application, iconFrame: hit.iconFrame)
            swallowedMouseUp = true
            return true
        }
        let frontmost =
            NSWorkspace.shared.frontmostApplication?.processIdentifier
            == hit.application.processIdentifier
        guard
            DockToolsPolicy.shouldHandleDockClick(
                action: preferences.clickAction, appIsFrontmost: frontmost, excluded: false)
        else { return false }
        switch preferences.clickAction {
        case .cycleWindows:
            _ = cycleWindow(for: hit.application)
        case .minimizeFrontWindow:
            _ = minimizeFrontWindow(for: hit.application)
        case .standard:
            return false
        }
        preview.close()
        swallowedMouseUp = true
        return true
    }

    private func showPreview(for application: NSRunningApplication, iconFrame: CGRect?) {
        let values = windows(for: application)
        guard !values.isEmpty else {
            preview.close()
            return
        }
        preview.show(
            application: application, windows: values,
            iconFrame: iconFrame.map(appKitFrame(fromAX:)),
            activate: { [weak self] window in
                guard let self else { return }
                _ = self.activate(window, application: application)
                self.preview.close()
            },
            move: { [weak self] offset in
                self?.preview.moveSelection(offset)
            })
    }

    private func scheduleHide() {
        guard preview.isVisible else { return }
        pendingHide?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.preview.close() }
        pendingHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.24, execute: work)
    }

    private func cancelHide() {
        pendingHide?.cancel()
        pendingHide = nil
    }

    private func windows(for application: NSRunningApplication) -> [DockToolsRuntimeWindow] {
        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.35)
        let elements: [AXUIElement] = attribute(appElement, kAXWindowsAttribute as CFString) ?? []
        let bundleIdentifier = application.bundleIdentifier ?? ""
        let appName = application.localizedName ?? bundleIdentifier
        return elements.enumerated().compactMap { index, element in
            let role: String? = attribute(element, kAXRoleAttribute as CFString)
            guard role == kAXWindowRole as String else { return nil }
            let title: String = attribute(element, kAXTitleAttribute as CFString) ?? ""
            let minimized: Bool = attribute(element, kAXMinimizedAttribute as CFString) ?? false
            let identifier = "\(application.processIdentifier):\(CFHash(element)):\(index)"
            return DockToolsRuntimeWindow(
                value: DockToolsWindow(
                    id: identifier, title: title, appName: appName,
                    bundleIdentifier: bundleIdentifier, pid: application.processIdentifier,
                    minimized: minimized),
                element: element)
        }
    }

    private func activate(
        _ window: DockToolsRuntimeWindow, application: NSRunningApplication
    ) -> Bool {
        if window.value.minimized {
            _ = AXUIElementSetAttributeValue(
                window.element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
        let activated = application.activate()
        let main = AXUIElementSetAttributeValue(
            window.element, kAXMainAttribute as CFString, kCFBooleanTrue)
        let raised = AXUIElementPerformAction(window.element, kAXRaiseAction as CFString)
        return activated && (main == .success || raised == .success)
    }

    private func cycleWindow(for application: NSRunningApplication) -> Bool {
        let values = windows(for: application)
        guard !values.isEmpty else { return false }
        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        let focused: AXUIElement? = attribute(appElement, kAXFocusedWindowAttribute as CFString)
        let current = focused.flatMap { focused in
            values.firstIndex { CFEqual($0.element, focused) }
        }
        guard
            let index = DockToolsPolicy.adjacentIndex(
                current: current, count: values.count, offset: 1)
        else { return false }
        return activate(values[index], application: application)
    }

    private func minimizeFrontWindow(for application: NSRunningApplication) -> Bool {
        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        let focused: AXUIElement? = attribute(appElement, kAXFocusedWindowAttribute as CFString)
        guard let focused else { return false }
        return AXUIElementSetAttributeValue(
            focused, kAXMinimizedAttribute as CFString, kCFBooleanTrue) == .success
    }

    private func dockHit(at point: CGPoint) -> DockToolsHit? {
        guard let dockPID = dockProcessID() else { return nil }
        let system = AXUIElementCreateSystemWide()
        var raw: AXUIElement?
        guard
            AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &raw)
                == .success,
            let raw
        else { return nil }
        let running = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !$0.isTerminated
        }
        for element in elementAndParents(raw) {
            var pid = pid_t()
            guard AXUIElementGetPid(element, &pid) == .success, pid == dockPID,
                let frame = frame(of: element)
            else { continue }
            if let url: URL = attribute(element, kAXURLAttribute as CFString) {
                let path = url.standardizedFileURL.path
                if let app = running.first(where: {
                    $0.bundleURL?.standardizedFileURL.path == path
                }) {
                    return DockToolsHit(application: app, iconFrame: frame)
                }
            }
        }
        return nil
    }

    private func dockProcessID() -> pid_t? {
        if let dockPID,
            NSRunningApplication(processIdentifier: dockPID)?.isTerminated == false
        {
            return dockPID
        }
        let pid = NSWorkspace.shared.runningApplications.first {
            $0.bundleIdentifier == "com.apple.dock"
        }?.processIdentifier
        dockPID = pid
        return pid
    }

    private func greenTarget(at point: CGPoint) -> DockToolsGreenTarget? {
        let system = AXUIElementCreateSystemWide()
        var raw: AXUIElement?
        guard
            AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &raw)
                == .success,
            let raw
        else { return nil }
        let role: String? = attribute(raw, kAXRoleAttribute as CFString)
        let subrole: String? = attribute(raw, kAXSubroleAttribute as CFString)
        guard role == kAXButtonRole as String,
            subrole == "AXFullScreenButton" || subrole == "AXZoomButton"
        else { return nil }
        guard
            let window = elementAndParents(raw).first(where: {
                let value: String? = attribute($0, kAXRoleAttribute as CFString)
                return value == kAXWindowRole as String
            }), let buttonFrame = frame(of: raw)
        else { return nil }
        var pid = pid_t()
        guard AXUIElementGetPid(window, &pid) == .success,
            let app = NSRunningApplication(processIdentifier: pid),
            !preferences.excludes(app.bundleIdentifier)
        else { return nil }
        return DockToolsGreenTarget(
            window: window, frame: buttonFrame,
            identifier: "\(pid):\(CFHash(window))")
    }

    private func toggleMaximize(_ target: DockToolsGreenTarget) {
        guard let current = frame(of: target.window),
            let screen = bestScreen(for: current)
        else { return }
        let maximized = axFrame(fromAppKit: screen.visibleFrame)
        let close =
            abs(current.minX - maximized.minX) < 3
            && abs(current.minY - maximized.minY) < 3
            && abs(current.width - maximized.width) < 6
            && abs(current.height - maximized.height) < 6
        let destination: CGRect
        if close, let restored = restoredFrames[target.identifier] {
            destination = restored
            restoredFrames[target.identifier] = nil
        } else {
            restoredFrames[target.identifier] = current
            destination = maximized
        }
        _ = setFrame(destination, on: target.window)
    }

    private func bestScreen(for axFrame: CGRect) -> NSScreen? {
        let appKit = appKitFrame(fromAX: axFrame)
        return NSScreen.screens.max { first, second in
            first.visibleFrame.intersection(appKit).area
                < second.visibleFrame.intersection(appKit).area
        }
    }

    private func setFrame(_ frame: CGRect, on element: AXUIElement) -> Bool {
        var point = frame.origin
        var size = frame.size
        guard let pointValue = AXValueCreate(.cgPoint, &point),
            let sizeValue = AXValueCreate(.cgSize, &size)
        else { return false }
        let moved = AXUIElementSetAttributeValue(
            element, kAXPositionAttribute as CFString, pointValue)
        let resized = AXUIElementSetAttributeValue(
            element, kAXSizeAttribute as CFString, sizeValue)
        return moved == .success && resized == .success
    }

    private func application(bundleIdentifier: String?) -> NSRunningApplication? {
        guard let bundleIdentifier else { return NSWorkspace.shared.frontmostApplication }
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .first { !$0.isTerminated }
    }

    private func elementAndParents(_ element: AXUIElement) -> [AXUIElement] {
        var result = [element]
        var current = element
        for _ in 0..<8 {
            guard let parent: AXUIElement = attribute(current, kAXParentAttribute as CFString)
            else { break }
            result.append(parent)
            current = parent
        }
        return result
    }

    private func frame(of element: AXUIElement) -> CGRect? {
        guard
            let point: CGPoint = axValue(element, kAXPositionAttribute as CFString, type: .cgPoint),
            let size: CGSize = axValue(element, kAXSizeAttribute as CFString, type: .cgSize),
            size.width > 0, size.height > 0
        else { return nil }
        return CGRect(origin: point, size: size)
    }

    private func attribute<T>(_ element: AXUIElement, _ name: CFString) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name, &value) == .success else { return nil }
        return value as? T
    }

    private func axValue<T>(
        _ element: AXUIElement, _ name: CFString, type: AXValueType
    ) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name, &value) == .success,
            let value, CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        var result: T?
        withUnsafeMutablePointer(to: &result) { pointer in
            _ = AXValueGetValue(value as! AXValue, type, pointer)
        }
        return result
    }

    private var screenTop: CGFloat {
        (NSScreen.screens.first { abs($0.frame.minX) < 0.5 && abs($0.frame.minY) < 0.5 }
            ?? NSScreen.main ?? NSScreen.screens.first)?.frame.maxY ?? 0
    }

    private func appKitFrame(fromAX frame: CGRect) -> CGRect {
        CGRect(x: frame.minX, y: screenTop - frame.maxY, width: frame.width, height: frame.height)
    }

    private func axFrame(fromAppKit frame: CGRect) -> CGRect {
        CGRect(x: frame.minX, y: screenTop - frame.maxY, width: frame.width, height: frame.height)
    }
}

@MainActor
private final class DockToolsPreviewStore: ObservableObject {
    @Published var application: NSRunningApplication?
    @Published var windows: [DockToolsRuntimeWindow] = []
    @Published var images: [String: NSImage] = [:]
    @Published var selectedIndex = 0
    var activate: ((DockToolsRuntimeWindow) -> Void)?

    var selectedID: String? {
        windows.indices.contains(selectedIndex) ? windows[selectedIndex].value.id : nil
    }
}

@MainActor
private final class DockToolsPreviewPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class DockToolsPreviewController {
    private let store = DockToolsPreviewStore()
    private var panel: DockToolsPreviewPanel?

    var isVisible: Bool { panel?.isVisible == true }
    var applicationPID: pid_t? { store.application?.processIdentifier }

    func show(
        application: NSRunningApplication, windows: [DockToolsRuntimeWindow],
        iconFrame: CGRect?, activate: @escaping (DockToolsRuntimeWindow) -> Void,
        move: @escaping (Int) -> Void
    ) {
        store.application = application
        store.windows = windows
        store.images = captureImages(for: windows)
        store.selectedIndex = 0
        store.activate = activate
        let panel = panel ?? makePanel(move: move)
        self.panel = panel
        let width = min(CGFloat(windows.count) * 218 + 32, 904)
        let size = NSSize(width: max(width, 250), height: 202)
        panel.setContentSize(size)
        panel.contentViewController?.view.frame = NSRect(origin: .zero, size: size)
        panel.setFrameOrigin(origin(for: size, iconFrame: iconFrame))
        panel.orderFrontRegardless()
    }

    func close() {
        panel?.orderOut(nil)
        store.windows = []
        store.images = [:]
        store.application = nil
    }

    func shutdown() {
        close()
        panel?.contentViewController = nil
        panel = nil
    }

    func moveSelection(_ offset: Int) {
        guard
            let index = DockToolsPolicy.adjacentIndex(
                current: store.selectedIndex, count: store.windows.count, offset: offset)
        else { return }
        store.selectedIndex = index
    }

    func contains(axPoint: CGPoint) -> Bool {
        guard let frame = panel?.frame, isVisible else { return false }
        let top = (NSScreen.main ?? NSScreen.screens.first)?.frame.maxY ?? 0
        let appKitPoint = CGPoint(x: axPoint.x, y: top - axPoint.y)
        return frame.insetBy(dx: -8, dy: -8).contains(appKitPoint)
    }

    private func makePanel(move: @escaping (Int) -> Void) -> DockToolsPreviewPanel {
        let panel = DockToolsPreviewPanel(
            contentRect: NSRect(x: 0, y: 0, width: 250, height: 202),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.contentViewController = NSHostingController(
            rootView: DockToolsPreviewView(store: store, move: move))
        return panel
    }

    private func origin(for size: NSSize, iconFrame: CGRect?) -> CGPoint {
        let screen =
            iconFrame.flatMap { frame in
                NSScreen.screens.first { $0.frame.intersects(frame) }
            } ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return .zero }
        let anchor =
            iconFrame
            ?? CGRect(x: screen.visibleFrame.midX, y: screen.visibleFrame.minY, width: 1, height: 1)
        var x = anchor.midX - size.width / 2
        var y = anchor.maxY + 10
        if anchor.midX < screen.visibleFrame.minX + 100 {
            x = anchor.maxX + 10
            y = anchor.midY - size.height / 2
        } else if anchor.midX > screen.visibleFrame.maxX - 100 {
            x = anchor.minX - size.width - 10
            y = anchor.midY - size.height / 2
        }
        x = min(max(x, screen.visibleFrame.minX + 8), screen.visibleFrame.maxX - size.width - 8)
        y = min(max(y, screen.visibleFrame.minY + 8), screen.visibleFrame.maxY - size.height - 8)
        return CGPoint(x: x, y: y)
    }

    private func captureImages(for windows: [DockToolsRuntimeWindow]) -> [String: NSImage] {
        guard CGPreflightScreenCaptureAccess() else { return [:] }
        let info =
            CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        var result: [String: NSImage] = [:]
        for window in windows {
            guard
                let match = info.first(where: {
                    $0[kCGWindowOwnerPID as String] as? pid_t == window.value.pid
                        && ($0[kCGWindowName as String] as? String ?? "") == window.value.title
                }), let windowID = match[kCGWindowNumber as String] as? CGWindowID,
                let image = CGWindowListCreateImage(
                    .null, .optionIncludingWindow, windowID,
                    [.boundsIgnoreFraming, .bestResolution])
            else { continue }
            result[window.value.id] = NSImage(cgImage: image, size: .zero)
        }
        return result
    }
}

private struct DockToolsPreviewView: View {
    @ObservedObject var store: DockToolsPreviewStore
    let move: (Int) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                appIcon
                    .frame(width: 22, height: 22)
                Text(store.application?.localizedName ?? "Windows")
                    .font(.system(size: 13, weight: .semibold))
                Text("\(store.windows.count)")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
                Spacer()
                Button {
                    move(-1)
                } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Previous window")
                Button {
                    move(1)
                } label: {
                    Image(systemName: "chevron.right")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Next window")
            }
            .padding(.horizontal, 14)
            .frame(height: 38)

            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(store.windows, id: \.value.id) { window in
                        Button {
                            store.activate?(window)
                        } label: {
                            DockToolsWindowCard(
                                window: window.value, image: store.images[window.value.id],
                                icon: store.application?.icon,
                                selected: store.selectedID == window.value.id)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Open \(window.value.displayTitle)")
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
            .scrollIndicators(.never)
        }
        .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(.white.opacity(0.14))
        }
    }

    private var appIcon: some View {
        let image =
            store.application?.icon
            ?? NSImage(systemSymbolName: "macwindow", accessibilityDescription: nil)!
        return Image(nsImage: image).resizable()
    }
}

private struct DockToolsWindowCard: View {
    let window: DockToolsWindow
    let image: NSImage?
    let icon: NSImage?
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(.black.opacity(0.18))
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .padding(4)
                } else if let icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 52, height: 52)
                } else {
                    Image(systemName: "macwindow")
                        .font(.system(size: 38))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 198, height: 116)
            HStack(spacing: 6) {
                Text(window.displayTitle)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if window.minimized {
                    Image(systemName: "minus.square")
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Minimized")
                }
            }
        }
        .padding(7)
        .background(
            selected ? Color.accentColor.opacity(0.2) : Color.white.opacity(0.06),
            in: RoundedRectangle(cornerRadius: 10)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(selected ? Color.accentColor.opacity(0.7) : .clear, lineWidth: 1.5)
        }
    }
}

@MainActor
private final class DockToolsAutoQuitMonitor {
    private var enabled = false
    private var observers: [pid_t: AXObserver] = [:]
    private var hadWindows: [pid_t: Bool] = [:]
    private var launchToken: NSObjectProtocol?
    private var terminateToken: NSObjectProtocol?

    func sync(enabled: Bool) {
        guard self.enabled != enabled else { return }
        self.enabled = enabled
        enabled ? start() : shutdown()
    }

    func shutdown() {
        enabled = false
        if let launchToken { NSWorkspace.shared.notificationCenter.removeObserver(launchToken) }
        if let terminateToken {
            NSWorkspace.shared.notificationCenter.removeObserver(terminateToken)
        }
        launchToken = nil
        terminateToken = nil
        for pid in Array(observers.keys) { detach(pid) }
    }

    func handle(element: AXUIElement, notification: String) {
        var pid = pid_t()
        guard AXUIElementGetPid(element, &pid) == .success else { return }
        if notification == kAXWindowCreatedNotification as String {
            refresh(pid)
        }
        if notification == kAXUIElementDestroyedNotification as String {
            scheduleCheck(pid)
        }
    }

    private func start() {
        guard AXIsProcessTrusted() else { return }
        for application in NSWorkspace.shared.runningApplications { attach(application) }
        launchToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard
                let application = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication
            else { return }
            MainActor.assumeIsolated { self?.attach(application) }
        }
        terminateToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard
                let application = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication
            else { return }
            MainActor.assumeIsolated { self?.detach(application.processIdentifier) }
        }
    }

    private func attach(_ application: NSRunningApplication) {
        let pid = application.processIdentifier
        guard enabled, application.activationPolicy == .regular, pid != getpid(),
            observers[pid] == nil
        else { return }
        var observer: AXObserver?
        guard AXObserverCreate(pid, dockToolsAXCallback, &observer) == .success, let observer
        else { return }
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 0.35)
        let info = Unmanaged.passUnretained(self).toOpaque()
        _ = AXObserverAddNotification(
            observer, appElement, kAXWindowCreatedNotification as CFString, info)
        CFRunLoopAddSource(
            CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        observers[pid] = observer
        refresh(pid)
    }

    private func detach(_ pid: pid_t) {
        if let observer = observers[pid] {
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        observers[pid] = nil
        hadWindows[pid] = nil
    }

    private func refresh(_ pid: pid_t) {
        guard let observer = observers[pid] else { return }
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 0.35)
        let windows: [AXUIElement] = attribute(appElement, kAXWindowsAttribute as CFString) ?? []
        let standard = windows.filter { window in
            let role: String? = attribute(window, kAXRoleAttribute as CFString)
            return role == kAXWindowRole as String
        }
        if !standard.isEmpty { hadWindows[pid] = true }
        let info = Unmanaged.passUnretained(self).toOpaque()
        for window in standard {
            _ = AXObserverAddNotification(
                observer, window, kAXUIElementDestroyedNotification as CFString, info)
        }
    }

    private func scheduleCheck(_ pid: pid_t) {
        for delay in [0.45, 1.2] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.check(pid)
            }
        }
    }

    private func check(_ pid: pid_t) {
        guard enabled, let application = NSRunningApplication(processIdentifier: pid) else {
            return
        }
        let preferences = DockToolsPreferences()
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 0.35)
        let windows: [AXUIElement] = attribute(appElement, kAXWindowsAttribute as CFString) ?? []
        let hasWindows = windows.contains { window in
            let role: String? = attribute(window, kAXRoleAttribute as CFString)
            return role == kAXWindowRole as String
        }
        guard
            DockToolsPolicy.shouldQuit(
                enabled: preferences.enabled && preferences.quitOnLastWindow,
                hadWindows: hadWindows[pid] == true, hasWindows: hasWindows,
                excluded: preferences.excludes(application.bundleIdentifier),
                terminated: application.isTerminated,
                regularApplication: application.activationPolicy == .regular)
        else { return }
        hadWindows[pid] = false
        application.terminate()
    }

    private func attribute<T>(_ element: AXUIElement, _ name: CFString) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name, &value) == .success else { return nil }
        return value as? T
    }
}

private extension CGRect {
    var area: CGFloat { max(width, 0) * max(height, 0) }
}
