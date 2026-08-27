import AppKit
import ApplicationServices
import Carbon.HIToolbox
import EdithKit
import SwiftUI

struct WindowSwitcherRuntimeWindow {
    let value: WindowSwitcherWindow
    let element: AXUIElement
    let application: NSRunningApplication
}

@MainActor
enum WindowSwitcherEnumerator {
    static func windows() -> [WindowSwitcherRuntimeWindow] {
        guard AXIsProcessTrusted() else { return [] }
        let defaults = SharedDefaults.store
        let rules = WindowSwitcherRuleSet(
            includedCSV: defaults.string(forKey: AppStorageKeys.WindowSwitcher.includedApps) ?? "",
            hiddenCSV: defaults.string(forKey: AppStorageKeys.WindowSwitcher.hiddenApps) ?? "")
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let applications = NSWorkspace.shared.runningApplications
            .filter { !$0.isTerminated && $0.processIdentifier != getpid() }
            .filter { application in
                guard let identifier = application.bundleIdentifier else { return false }
                return rules.permits(
                    bundleIdentifier: identifier,
                    regular: application.activationPolicy == .regular)
            }
            .sorted { left, right in
                if left.processIdentifier == frontPID { return true }
                if right.processIdentifier == frontPID { return false }
                return (left.localizedName ?? "").localizedStandardCompare(
                    right.localizedName ?? "") == .orderedAscending
            }

        return applications.flatMap { application -> [WindowSwitcherRuntimeWindow] in
            guard let bundleIdentifier = application.bundleIdentifier else { return [] }
            let appName = application.localizedName ?? bundleIdentifier
            let appElement = AXUIElementCreateApplication(application.processIdentifier)
            let elements: [AXUIElement] =
                attribute(appElement, kAXWindowsAttribute as CFString) ?? []
            return elements.enumerated().compactMap { index, element in
                let role: String? = attribute(element, kAXRoleAttribute as CFString)
                guard role == kAXWindowRole as String else { return nil }
                let title: String = attribute(element, kAXTitleAttribute as CFString) ?? ""
                let minimized: Bool = attribute(element, kAXMinimizedAttribute as CFString) ?? false
                let value = WindowSwitcherWindow(
                    id: "\(application.processIdentifier):\(index)", appName: appName,
                    bundleIdentifier: bundleIdentifier, title: title, isMinimized: minimized,
                    pid: application.processIdentifier)
                return WindowSwitcherRuntimeWindow(
                    value: value, element: element, application: application)
            }
        }
    }

    static func activate(_ window: WindowSwitcherRuntimeWindow) -> Bool {
        if window.value.isMinimized {
            AXUIElementSetAttributeValue(
                window.element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
        let activated = window.application.activate()
        let madeMain = AXUIElementSetAttributeValue(
            window.element, kAXMainAttribute as CFString, kCFBooleanTrue)
        let raised = AXUIElementPerformAction(window.element, kAXRaiseAction as CFString)
        return activated && (madeMain == .success || raised == .success)
    }

    static func cycleFrontApplication() -> Bool {
        guard let application = NSWorkspace.shared.frontmostApplication else { return false }
        let candidates = windows().filter { $0.value.pid == application.processIdentifier }
        guard !candidates.isEmpty else { return false }
        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        let focused: AXUIElement? = attribute(
            appElement, kAXFocusedWindowAttribute as CFString)
        let current =
            focused.flatMap { focused in
                candidates.firstIndex { CFEqual($0.element, focused) }
            } ?? -1
        return activate(candidates[(current + 1) % candidates.count])
    }

    static func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    private static func attribute<T>(_ element: AXUIElement, _ name: CFString) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name, &value) == .success else { return nil }
        return value as? T
    }
}

@MainActor
final class WindowSwitcherStore: ObservableObject {
    @Published var query = "" {
        didSet { selectedIndex = 0 }
    }
    @Published private(set) var windows: [WindowSwitcherRuntimeWindow] = []
    @Published private(set) var authorized = AXIsProcessTrusted()
    @Published var selectedIndex = 0
    @Published private(set) var grouped = true

    var visible: [WindowSwitcherRuntimeWindow] {
        let identifiers = Set(
            WindowSwitcherCollection.filtered(windows.map(\.value), query: query).map(\.id))
        return windows.filter { identifiers.contains($0.value.id) }
    }

    var groups: [WindowSwitcherGroup] {
        WindowSwitcherCollection.grouped(visible.map(\.value))
    }

    func reload() {
        authorized = AXIsProcessTrusted()
        grouped =
            SharedDefaults.store.object(forKey: AppStorageKeys.WindowSwitcher.grouped)
            as? Bool ?? true
        windows = authorized ? WindowSwitcherEnumerator.windows() : []
        selectedIndex = min(selectedIndex, max(visible.count - 1, 0))
    }

    func move(_ delta: Int) {
        guard !visible.isEmpty else { return }
        selectedIndex = (selectedIndex + delta + visible.count) % visible.count
    }

    func selected() -> WindowSwitcherRuntimeWindow? {
        visible.indices.contains(selectedIndex) ? visible[selectedIndex] : nil
    }

    func select(id: String) {
        guard let index = visible.firstIndex(where: { $0.value.id == id }) else { return }
        selectedIndex = index
    }
}

final class WindowSwitcherPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class WindowSwitcherController: NSObject, NSWindowDelegate {
    private let store = WindowSwitcherStore()
    private var panel: WindowSwitcherPanel?
    private var keyMonitor: Any?

    func show() {
        store.query = ""
        store.reload()
        let panel = panel ?? makePanel()
        self.panel = panel
        let screen = NSScreen.main ?? NSScreen.screens.first
        if let screen {
            panel.setFrameOrigin(
                NSPoint(
                    x: screen.visibleFrame.midX - panel.frame.width / 2,
                    y: screen.visibleFrame.midY - panel.frame.height / 2))
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        installKeyMonitor()
    }

    func close() {
        panel?.orderOut(nil)
        removeKeyMonitor()
    }

    func activate(id: String) -> Bool {
        guard let window = WindowSwitcherEnumerator.windows().first(where: { $0.value.id == id })
        else { return false }
        close()
        return WindowSwitcherEnumerator.activate(window)
    }

    func activateStored(id: String) -> Bool {
        guard let window = store.windows.first(where: { $0.value.id == id }) else { return false }
        close()
        return WindowSwitcherEnumerator.activate(window)
    }

    func activateSelection() -> Bool {
        guard let window = store.selected() else { return false }
        close()
        return WindowSwitcherEnumerator.activate(window)
    }

    func cycle() -> Bool {
        WindowSwitcherEnumerator.cycleFrontApplication()
    }

    func list() -> [WindowSwitcherWindow] {
        WindowSwitcherEnumerator.windows().map(\.value)
    }

    func shutdown() {
        close()
        panel?.delegate = nil
        panel?.contentViewController = nil
        panel = nil
    }

    func windowDidResignKey(_ notification: Notification) {
        close()
    }

    private func makePanel() -> WindowSwitcherPanel {
        let contentSize = NSSize(width: 680, height: 520)
        let panel = WindowSwitcherPanel(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.delegate = self
        panel.contentViewController = NSHostingController(
            rootView: WindowSwitcherView(
                store: store,
                activate: { [weak self] id in _ = self?.activateStored(id: id) }
            )
            .frame(width: contentSize.width, height: contentSize.height))
        panel.setContentSize(contentSize)
        return panel
    }

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated { self?.handleKey(event) ?? false }
            return handled ? nil : event
        }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case UInt16(kVK_Escape):
            close()
        case UInt16(kVK_Return), UInt16(kVK_ANSI_KeypadEnter):
            _ = activateSelection()
        case UInt16(kVK_DownArrow), UInt16(kVK_Tab):
            store.move(event.modifierFlags.contains(.shift) ? -1 : 1)
        case UInt16(kVK_UpArrow):
            store.move(-1)
        default:
            return false
        }
        return true
    }

    private func removeKeyMonitor() {
        guard let keyMonitor else { return }
        NSEvent.removeMonitor(keyMonitor)
        self.keyMonitor = nil
    }
}

@MainActor
final class WindowSwitcherService {
    let controller = WindowSwitcherController()

    init() {
        registerHotKeys()
    }

    func syncSettings() {
        registerHotKeys()
    }

    func shutdown() {
        GlobalHotKey.clear(id: GlobalHotKey.ID.windowSwitcher)
        GlobalHotKey.clear(id: GlobalHotKey.ID.windowCycle)
        controller.shutdown()
    }

    func perform(_ info: [AnyHashable: Any]) {
        let requestID = info[WindowSwitcherIPC.requestIDKey] as? String ?? ""
        let operation = (info[WindowSwitcherIPC.operationKey] as? String)
            .flatMap(WindowSwitcherOperation.init(rawValue:))
        var status = "ok"
        var payload = ""
        switch operation {
        case .list:
            guard AXIsProcessTrusted() else {
                status = "notAuthorized"
                break
            }
            payload = WindowSwitcherIPC.encode(controller.list())
        case .show:
            controller.show()
        case .activate:
            let id = info[WindowSwitcherIPC.windowIDKey] as? String ?? ""
            status = controller.activate(id: id) ? "ok" : "notFound"
        case .cycle:
            status = controller.cycle() ? "ok" : "notFound"
        case nil:
            status = "invalid"
        }
        IPC.post(
            IPC.Name.windowSwitcherOperationResult,
            userInfo: [
                WindowSwitcherIPC.requestIDKey: requestID,
                WindowSwitcherIPC.statusKey: status,
                WindowSwitcherIPC.payloadKey: payload,
            ])
    }

    private func registerHotKeys() {
        GlobalHotKey.set(
            id: GlobalHotKey.ID.windowSwitcher,
            keyCode: SharedDefaults.store.object(
                forKey: AppStorageKeys.WindowSwitcher.showHotKeyCode) as? Int ?? kVK_Tab,
            modifiers: SharedDefaults.store.object(
                forKey: AppStorageKeys.WindowSwitcher.showHotKeyMods) as? Int ?? optionKey
        ) { [weak self] in
            self?.controller.show()
        }
        GlobalHotKey.set(
            id: GlobalHotKey.ID.windowCycle,
            keyCode: SharedDefaults.store.object(
                forKey: AppStorageKeys.WindowSwitcher.cycleHotKeyCode) as? Int ?? kVK_ANSI_Grave,
            modifiers: SharedDefaults.store.object(
                forKey: AppStorageKeys.WindowSwitcher.cycleHotKeyMods) as? Int ?? optionKey
        ) { [weak self] in
            _ = self?.controller.cycle()
        }
    }
}

private struct WindowSwitcherView: View {
    @ObservedObject var store: WindowSwitcherStore
    let activate: (String) -> Void
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "rectangle.stack.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.tint)
                TextField("Search windows", text: $store.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 22, weight: .semibold))
                    .focused($searchFocused)
                Text("esc")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            }
            .padding(20)

            Divider()

            if !store.authorized {
                ContentUnavailableView {
                    Label("Accessibility required", systemImage: "figure.wave")
                } description: {
                    Text("Edith needs Accessibility access to read titles and focus windows.")
                } actions: {
                    Button("Grant Accessibility") {
                        WindowSwitcherEnumerator.requestAccessibility()
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.visible.isEmpty {
                ContentUnavailableView.search(text: store.query)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            if store.grouped {
                                ForEach(store.groups) { group in
                                    Text("\(group.appName)  ·  \(group.windows.count)")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                        .textCase(.uppercase)
                                        .padding(.top, 8)
                                    ForEach(group.windows) { window in
                                        row(window)
                                    }
                                }
                            } else {
                                ForEach(store.visible.map(\.value)) { window in
                                    row(window)
                                }
                            }
                        }
                        .padding(16)
                    }
                    .onChange(of: store.selectedIndex) {
                        guard let id = store.selected()?.value.id else { return }
                        withAnimation(.easeOut(duration: 0.12)) {
                            proxy.scrollTo(id, anchor: .center)
                        }
                    }
                }
            }

            Divider()
            HStack(spacing: 16) {
                Label("move", systemImage: "arrow.up.arrow.down")
                Label("open", systemImage: "return")
                Spacer()
                Text("\(store.visible.count) window\(store.visible.count == 1 ? "" : "s")")
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 20)
            .frame(height: 42)
        }
        .background(.ultraThickMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .onAppear { searchFocused = true }
    }

    private func row(_ window: WindowSwitcherWindow) -> some View {
        let selected = store.selected()?.value.id == window.id
        return Button {
            activate(window.id)
        } label: {
            HStack(spacing: 13) {
                appIcon(window)
                    .frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 3) {
                    Text(window.displayTitle)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                    Text(window.appName)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if window.isMinimized {
                    Label("Minimized", systemImage: "minus.square")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 3)
            .frame(height: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(.edith(.row, selected: selected))
        .edithButtonTarget(.row)
        .id(window.id)
        .onHover { hovering in
            if hovering { store.select(id: window.id) }
        }
    }

    private func appIcon(_ window: WindowSwitcherWindow) -> Image {
        let icon =
            NSRunningApplication(processIdentifier: window.pid)?.icon
            ?? NSImage(systemSymbolName: "macwindow", accessibilityDescription: nil)!
        return Image(nsImage: icon)
            .resizable()
    }
}
