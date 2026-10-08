import ApplicationServices
import CoreGraphics
import Darwin
import EdithKit
import Foundation

struct SweaterSpawnPayload {
    var space: UInt64
    var window: UInt32
}

@MainActor
final class SweaterWindowTracker {
    private(set) var borders: [SkyLight.WindowID: SweaterBorder] = [:]
    private let connection: SkyLight.Connection
    private let ownPID = getpid()
    private var settingsProvider: () -> SweaterRuntimeSettings
    private var orderCheckPending = false
    private var focusGeneration: UInt64 = 0
    private var focusDeadline: Double = 0
    private var resizeFollowUps: [SkyLight.WindowID: UInt64] = [:]
    private var resizeFollowUpCounter: UInt64 = 0

    nonisolated(unsafe) static weak var active: SweaterWindowTracker?

    var onActivity: (() -> Void)?

    var settings: SweaterRuntimeSettings { settingsProvider() }

    init(settings: @escaping () -> SweaterRuntimeSettings) {
        connection = SweaterWindowServer.mainConnection
        settingsProvider = settings
        Self.active = self
        registerEvents()
    }

    func shutDown() {
        removeAll()
        if Self.active === self { Self.active = nil }
    }

    private func registerEvents() {
        guard let register = SkyLight.registerNotifyProc else { return }
        let modify = unsafeBitCast(sweaterModifyHandler, to: UnsafeMutableRawPointer.self)
        let spawn = unsafeBitCast(sweaterSpawnHandler, to: UnsafeMutableRawPointer.self)
        let simple = unsafeBitCast(sweaterSimpleHandler, to: UnsafeMutableRawPointer.self)
        for event in [
            SweaterEvent.windowClose, SweaterEvent.windowMove, SweaterEvent.windowResize,
            SweaterEvent.windowLevel, SweaterEvent.windowUnhide, SweaterEvent.windowHide,
            SweaterEvent.windowTitle, SweaterEvent.windowReorder, SweaterEvent.windowUpdate,
        ] {
            _ = register(modify, event, nil)
        }
        _ = register(spawn, SweaterEvent.windowCreate, nil)
        _ = register(spawn, SweaterEvent.windowDestroy, nil)
        _ = register(simple, SweaterEvent.spaceChange, nil)
        _ = register(simple, SweaterEvent.frontChange, nil)
    }

    func isOwnWindow(_ window: SkyLight.WindowID) -> Bool {
        SweaterWindowServer.ownerPID(of: window, connection: connection) == ownPID
    }

    static let processPathLimit = 4096

    func processName(for pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Self.processPathLimit)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let name = String(cString: buffer)
        guard name == "Electron" else { return name.isEmpty ? nil : name }
        var path = [CChar](repeating: 0, count: Self.processPathLimit)
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return name }
        return SweaterCollection.appName(fromExecutablePath: String(cString: path)) ?? name
    }

    @discardableResult
    func create(window: SkyLight.WindowID, space: SkyLight.SpaceID) -> Bool {
        guard let pid = SweaterWindowServer.ownerPID(of: window, connection: connection),
            pid != ownPID, let name = processName(for: pid), settings.allows(app: name),
            let list = SkyLightSupport.windowArray([window])
        else { return false }

        let created = SkyLightSupport.withIterator(connection: connection, windows: list) {
            iterator -> Bool? in
            guard let count = SkyLight.windowIteratorGetCount, count(iterator) > 0,
                SkyLight.windowIteratorAdvance?(iterator).boolValue == true,
                SkyLightSupport.isSuitable(iterator)
            else { return nil }

            let radius = SweaterWindowServer.cornerRadius(of: iterator)
            let existing = borders[window]
            let border = existing ?? SweaterBorder(target: window)
            border.radius = radius
            border.innerRadius = radius + 1
            border.app = name
            border.space = space
            border.metadataDirty = true
            borders[window] = border
            border.update(settings: settings)
            return existing == nil
        }
        guard let created else { return false }
        updateNotifications()
        return created
    }

    @discardableResult
    func destroy(window: SkyLight.WindowID, space: SkyLight.SpaceID) -> Bool {
        guard let border = borders[window],
            border.space == space || border.sticky || space == 0
        else { return false }
        borders.removeValue(forKey: window)
        resizeFollowUps.removeValue(forKey: window)
        border.tearDown()
        updateNotifications()
        return true
    }

    func removeAll() {
        for border in borders.values { border.tearDown() }
        borders.removeAll()
        resizeFollowUps.removeAll()
        updateNotifications()
    }

    func recreateAll() {
        removeAll()
        addExistingWindows()
    }

    func updateNotifications() {
        guard let request = SkyLight.requestNotificationsForWindows else { return }
        var windows = Array(borders.keys)
        if windows.isEmpty {
            var empty: SkyLight.WindowID = 0
            _ = request(connection, &empty, 0)
            return
        }
        _ = request(connection, &windows, Int32(windows.count))
    }

    func redrawAll() {
        let settings = settings
        for border in borders.values {
            border.needsRedraw = true
            border.update(settings: settings)
        }
    }

    func reorderAll() {
        let settings = settings
        for border in borders.values { border.reorder(settings: settings) }
    }

    func update(window: SkyLight.WindowID) {
        guard let border = borders[window] else { return }
        border.metadataDirty = true
        border.update(settings: settings)
    }

    func move(window: SkyLight.WindowID) {
        borders[window]?.updateGeometry(settings: settings)
    }

    func resize(window: SkyLight.WindowID) {
        guard let border = borders[window] else { return }
        border.updateGeometry(settings: settings)
        scheduleResizeFollowUp(window: window)
    }

    private func scheduleResizeFollowUp(window: SkyLight.WindowID) {
        resizeFollowUpCounter += 1
        let token = resizeFollowUpCounter
        resizeFollowUps[window] = token
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(32))
            guard let self, self.resizeFollowUps[window] == token else { return }
            self.resizeFollowUps.removeValue(forKey: window)
            self.borders[window]?.updateGeometry(settings: self.settings)
        }
    }

    func hide(window: SkyLight.WindowID) {
        resizeFollowUps.removeValue(forKey: window)
        borders[window]?.hide()
    }

    func unhide(window: SkyLight.WindowID) {
        guard let border = borders[window] else { return }
        border.metadataDirty = true
        border.update(settings: settings)
    }

    func scheduleOrderCheck() {
        guard !orderCheckPending else { return }
        orderCheckPending = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(30))
            guard let self else { return }
            self.orderCheckPending = false
            self.reorderAll()
        }
    }

    func scheduleFocusCheck(afterMilliseconds delay: Int) {
        let now = CFAbsoluteTimeGetCurrent()
        let deadline = now + Double(delay) / 1000
        if focusDeadline != 0, focusDeadline <= deadline { return }
        focusDeadline = deadline
        focusGeneration += 1
        let generation = focusGeneration
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(delay))
            guard let self, self.focusGeneration == generation else { return }
            self.focusDeadline = 0
            self.determineAndFocusActiveWindow()
        }
    }

    func determineAndFocusActiveWindow() {
        let settings = settings
        var front: SkyLight.WindowID = 0
        if settings.accessibilityFocus { front = SweaterAccessibility.frontWindow(connection) }
        if front == 0 { front = SweaterWindowServer.frontWindow(connection: connection) }
        if focus(window: front) { return }
        guard front != 0 else { return }
        let space = SweaterWindowServer.space(of: front, connection: connection)
        if create(window: front, space: space) { _ = focus(window: front) }
    }

    @discardableResult
    private func focus(window: SkyLight.WindowID) -> Bool {
        let settings = settings
        var found = false
        let repaints = settings.unfocusedDim > 0
        for border in borders.values {
            if border.focused, border.targetWindow != window {
                border.focused = false
                border.metadataDirty = true
                if repaints { border.needsRedraw = true }
                border.update(settings: settings)
            }
            if !border.focused, border.targetWindow == window {
                border.focused = true
                border.metadataDirty = true
                if repaints { border.needsRedraw = true }
                border.update(settings: settings)
            }
            if border.targetWindow == window { found = true }
        }
        return found
    }

    func addExistingWindows() {
        let spaces = SweaterWindowServer.allSpaces(connection: connection)
        guard !spaces.isEmpty,
            let list = SweaterWindowServer.windows(onSpaces: spaces, connection: connection),
            CFArrayGetCount(list) > 0
        else { return }
        discover(in: list, refreshExisting: false)
        updateNotifications()
    }

    func drawBordersOnCurrentSpaces() {
        let spaces = SweaterWindowServer.visibleSpaces(connection: connection)
        guard !spaces.isEmpty,
            let list = SweaterWindowServer.windows(onSpaces: spaces, connection: connection)
        else { return }
        discover(in: list, refreshExisting: true)
    }

    private func discover(in list: CFArray, refreshExisting: Bool) {
        let settings = settings
        _ = SkyLightSupport.withIterator(connection: connection, windows: list) {
            iterator -> Bool? in
            guard let advance = SkyLight.windowIteratorAdvance,
                let windowOf = SkyLight.windowIteratorGetWindowID
            else { return nil }
            while advance(iterator).boolValue {
                guard SkyLightSupport.isSuitable(iterator) else { continue }
                let window = windowOf(iterator)
                if let border = borders[window] {
                    guard refreshExisting else { continue }
                    border.metadataDirty = true
                    border.update(settings: settings)
                } else {
                    let space = SweaterWindowServer.space(of: window, connection: connection)
                    create(window: window, space: space)
                }
            }
            return true
        }
    }
}

enum SweaterAccessibility {
    static func frontWindow(_ connection: SkyLight.Connection) -> SkyLight.WindowID {
        guard AXIsProcessTrusted(), let frontProcess = SkyLight.getFrontProcess,
            let connectionForPSN = SkyLight.getConnectionIDForPSN,
            let pidOf = SkyLight.connectionGetPID, let windowOf = axWindowIdentifier
        else { return 0 }
        var psn = ProcessSerialNumber()
        guard frontProcess(&psn) == noErr else { return 0 }
        var target: SkyLight.Connection = 0
        guard connectionForPSN(connection, &psn, &target) == .success else { return 0 }
        var pid: pid_t = 0
        guard pidOf(target, &pid) == .success, pid > 0 else { return 0 }

        let application = AXUIElementCreateApplication(pid)
        guard AXUIElementSetMessagingTimeout(application, 0.008) == .success else { return 0 }
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            application, kAXFocusedWindowAttribute as CFString, &value)
        guard error == .success, let window = value,
            CFGetTypeID(window) == AXUIElementGetTypeID()
        else { return 0 }
        let element = window as! AXUIElement
        guard AXUIElementSetMessagingTimeout(element, 0.008) == .success else { return 0 }
        var identifier: SkyLight.WindowID = 0
        _ = windowOf(element, &identifier)
        return identifier
    }

    private static let axWindowIdentifier:
        (
            @convention(c) (AXUIElement, UnsafeMutablePointer<UInt32>) -> AXError
        )? = {
            guard let handle = dlopen(nil, RTLD_NOW),
                let symbol = dlsym(handle, "_AXUIElementGetWindow")
            else { return nil }
            return unsafeBitCast(
                symbol,
                to: (@convention(c) (AXUIElement, UnsafeMutablePointer<UInt32>) -> AXError).self)
        }()
}

private let sweaterSpawnHandler:
    @convention(c) (UInt32, UnsafeMutableRawPointer?, Int, UnsafeMutableRawPointer?) -> Void = {
        event, data, length, _ in
        guard let data, length >= MemoryLayout<SweaterSpawnPayload>.size else { return }
        let payload = data.loadUnaligned(as: SweaterSpawnPayload.self)
        Task { @MainActor in
            SweaterWindowTracker.active?.handleSpawn(event: event, payload: payload)
        }
    }

private let sweaterModifyHandler:
    @convention(c) (UInt32, UnsafeMutableRawPointer?, Int, UnsafeMutableRawPointer?) -> Void = {
        event, data, length, _ in
        guard let data, length >= MemoryLayout<UInt32>.size else { return }
        let window = data.loadUnaligned(as: UInt32.self)
        guard window != 0 else { return }
        Task { @MainActor in
            SweaterWindowTracker.active?.handleModify(event: event, window: window)
        }
    }

private let sweaterSimpleHandler:
    @convention(c) (UInt32, UnsafeMutableRawPointer?, Int, UnsafeMutableRawPointer?) -> Void = {
        event, _, _, _ in
        Task { @MainActor in
            SweaterWindowTracker.active?.handleSimple(event: event)
        }
    }

extension SweaterWindowTracker {
    func handleSpawn(event: UInt32, payload: SweaterSpawnPayload) {
        onActivity?()
        let window = payload.window
        let space = payload.space
        if window != 0, event == SweaterEvent.windowDestroy, borders[window] != nil {
            hide(window: window)
            scheduleOrderCheck()
            scheduleFocusCheck(afterMilliseconds: 0)
            return
        }
        guard window != 0, space != 0, !isOwnWindow(window) else { return }
        scheduleOrderCheck()

        if event == SweaterEvent.windowCreate {
            guard borders[window] == nil else { return }
            if create(window: window, space: space) { determineAndFocusActiveWindow() }
        } else if event == SweaterEvent.windowDestroy {
            _ = destroy(window: window, space: space)
            determineAndFocusActiveWindow()
        }
    }

    func handleModify(event: UInt32, window: SkyLight.WindowID) {
        onActivity?()
        if borders[window] == nil {
            if event == SweaterEvent.windowMove || event == SweaterEvent.windowResize { return }
            if isOwnWindow(window) { return }
        }
        switch event {
        case SweaterEvent.windowMove: move(window: window)
        case SweaterEvent.windowResize: resize(window: window)
        case SweaterEvent.windowReorder:
            update(window: window)
            scheduleFocusCheck(afterMilliseconds: 10)
            scheduleOrderCheck()
        case SweaterEvent.windowLevel:
            update(window: window)
            scheduleOrderCheck()
        case SweaterEvent.windowTitle, SweaterEvent.windowUpdate:
            scheduleFocusCheck(afterMilliseconds: 50)
        case SweaterEvent.windowUnhide:
            unhide(window: window)
            scheduleOrderCheck()
        case SweaterEvent.windowHide:
            hide(window: window)
            scheduleOrderCheck()
        case SweaterEvent.windowClose:
            _ = destroy(window: window, space: 0)
            scheduleOrderCheck()
        default: break
        }
    }

    func handleSimple(event: UInt32) {
        onActivity?()
        if event == SweaterEvent.spaceChange {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(20))
                self?.drawBordersOnCurrentSpaces()
            }
        } else {
            scheduleFocusCheck(afterMilliseconds: 50)
            scheduleOrderCheck()
        }
    }
}
