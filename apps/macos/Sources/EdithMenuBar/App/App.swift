import Carbon.HIToolbox
import EdithKit
import SwiftUI

enum Logo {
    private static func loadTile() -> NSImage? {
        Bundle.main.url(forResource: "MenuBar", withExtension: "png")
            .flatMap { NSImage(contentsOf: $0) }
    }

    static let menuBar: NSImage = {
        let image =
            loadTile()
            ?? NSImage(systemSymbolName: "eyeglasses", accessibilityDescription: nil)!
        image.size = NSSize(width: 20, height: 20)
        return image
    }()

    static let header: NSImage =
        loadTile()
        ?? NSImage(systemSymbolName: "eyeglasses", accessibilityDescription: nil)!
}

@MainActor
private func migratedServices() -> AppServices {
    let d = UserDefaults.standard
    if !d.bool(forKey: "migratedFromControlCenter"),
        let old = d.persistentDomain(forName: "com.pulkit.control-center")
    {
        for (key, value) in old where !key.hasPrefix("NSStatusItem") {
            if d.object(forKey: key) == nil { d.set(value, forKey: key) }
        }
        d.set(true, forKey: "migratedFromControlCenter")
    }
    SharedDefaults.migrate()
    return AppServices()
}

@main
struct EdithApp: App {
    private let services = migratedServices()

    init() {
        _ = ProcessUptime.launchedAt

        for key in [
            "NSStatusItem VisibleCC Item-0", "NSStatusItem VisibleCC Item-1",
            "NSStatusItem VisibleCC limits",
        ] {
            UserDefaults.standard.set(true, forKey: key)
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { _ in
            dismissPanel()
        }
        NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: nil, queue: .main
        ) { note in
            guard let panel = note.object as? NSWindow,
                panel.className.contains("MenuBarExtraWindow")
            else { return }
            DispatchQueue.main.async { [weak panel] in
                if let panel, panel.isVisible, !NSColorPanel.shared.isVisible {
                    dismissPanel()
                }
            }
        }
        let names: [Notification.Name] = [
            NSWindow.didBecomeKeyNotification,
            NSWindow.didResizeNotification,
            NSWindow.didMoveNotification,
            NSWindow.didChangeOcclusionStateNotification,
        ]
        for name in names {
            NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { note in
                guard let panel = note.object as? NSWindow,
                    panel.className.contains("MenuBarExtraWindow")
                else { return }
                MainActor.assumeIsolated {
                    centerPanelUnderIcon(panel)
                    MiniPanel.shared.sync()
                }
                DispatchQueue.main.async { [weak panel] in
                    MainActor.assumeIsolated {
                        if let panel, panel.isVisible { centerPanelUnderIcon(panel) }
                        MiniPanel.shared.sync()
                    }
                }
            }
        }
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { note in
            guard let window = note.object as? NSWindow,
                window.className.contains("MenuBarExtraWindow")
            else { return }
            Task { @MainActor in MiniPanel.shared.sync() }
        }
        HotKey.register()
        ClipboardHotKey.register()
        FocusDimHotKey.register()
        PresenterHotKey.register()
        SettingsBackup.shared.start()
        applyAppearance(SharedDefaults.store.string(forKey: "appearance") ?? "system")
        let services = services
        _ = IPC.observe(IPC.Name.settingsChanged) {
            HotKey.register()
            ClipboardHotKey.register()
            SettingsBackup.shared.scheduleClipboardBackup()
            FocusDimHotKey.register()
            PresenterHotKey.register()
            applyAppearance(SharedDefaults.store.string(forKey: "appearance") ?? "system")
            services.sync()
            services.usage?.refreshMenuBarItem()
            services.system?.syncPreventSleep()
            services.usage?.notifier.clearStateIfMasterOff()
            services.focusDim?.applySettings()
        }
        _ = IPC.observe(IPC.Name.presenterAutoActiveChanged) {
            services.usage?.refreshMenuBarItem()
        }
        _ = IPC.observe(IPC.Name.requestTestNotification) {
            Task { _ = await services.usage?.notifier.sendTest() }
        }
        PermissionsModel.shared.startIPCBridge()
        PermissionsModel.shared.refresh()

        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53, !NSColorPanel.shared.isVisible,
                NSApp.windows.contains(where: {
                    $0.className.contains("MenuBarExtraWindow") && $0.isVisible
                })
            {
                dismissPanel()
                return nil
            }
            return event
        }
    }

    var body: some Scene {
        MenuBarExtra {
            RootView()
                .environmentObject(services)
        } label: {
            Image(nsImage: Logo.menuBar)
        }
        .menuBarExtraStyle(.window)
    }
}

private func dispatchGlobalHotKey(_ id: UInt32) {
    if let action = GlobalHotKey.actions[id] {
        DispatchQueue.main.async(execute: action)
    }
}

enum GlobalHotKey {
    enum ID {
        static let panel: UInt32 = 1
        static let clipboard: UInt32 = 2
        static let notchShelf: UInt32 = 3
        static let focusDim: UInt32 = 4
        static let colorPicker: UInt32 = 5
        static let pixelRuler: UInt32 = 6
        static let presenterToggle: UInt32 = 7
    }

    fileprivate static var refs: [UInt32: EventHotKeyRef] = [:]
    fileprivate static var actions: [UInt32: () -> Void] = [:]
    private static var handlerInstalled = false

    private static func installHandlerOnce() {
        guard !handlerInstalled else { return }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ in
                guard let event else { return noErr }
                var hotKeyID = EventHotKeyID()
                GetEventParameter(
                    event, EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil,
                    &hotKeyID)
                dispatchGlobalHotKey(hotKeyID.id)
                return noErr
            }, 1, &eventType, nil, nil)
        handlerInstalled = true
    }

    static func set(id: UInt32, keyCode: Int, modifiers: Int, action: @escaping () -> Void) {
        installHandlerOnce()
        clear(id: id)
        actions[id] = action
        let hotKeyID = EventHotKeyID(signature: OSType(0x4544_4954), id: id)
        var ref: EventHotKeyRef?
        RegisterEventHotKey(
            UInt32(keyCode), UInt32(modifiers), hotKeyID, GetApplicationEventTarget(), 0, &ref)
        refs[id] = ref
    }

    static func clear(id: UInt32) {
        if let ref = refs.removeValue(forKey: id) {
            UnregisterEventHotKey(ref)
        }
        actions.removeValue(forKey: id)
    }
}

enum HotKey {
    static var code: Int {
        SharedDefaults.store.object(forKey: "hotKeyCode") as? Int ?? kVK_ANSI_E
    }
    static var mods: Int {
        SharedDefaults.store.object(forKey: "hotKeyMods") as? Int ?? (cmdKey | optionKey)
    }
    static var label: String {
        SharedDefaults.store.string(forKey: "hotKeyLabel") ?? "⌥⌘E"
    }

    static func register() {
        GlobalHotKey.set(id: GlobalHotKey.ID.panel, keyCode: code, modifiers: mods) {
            togglePanel()
        }
    }

    static func unregister() {
        GlobalHotKey.clear(id: GlobalHotKey.ID.panel)
    }

    static func save(code: Int, mods: Int, label: String) {
        SharedDefaults.store.set(code, forKey: "hotKeyCode")
        SharedDefaults.store.set(mods, forKey: "hotKeyMods")
        SharedDefaults.store.set(label, forKey: "hotKeyLabel")
    }
}

enum ClipboardHotKey {
    static var code: Int {
        SharedDefaults.store.object(forKey: "clipboardHotKeyCode") as? Int ?? kVK_ANSI_C
    }
    static var mods: Int {
        SharedDefaults.store.object(forKey: "clipboardHotKeyMods") as? Int
            ?? (controlKey | shiftKey)
    }
    static var label: String {
        SharedDefaults.store.string(forKey: "clipboardHotKeyLabel") ?? "⌃⇧C"
    }

    static func register() {
        let enabled = SharedDefaults.store.object(forKey: "clipboardEnabled") as? Bool ?? false
        guard enabled else {
            GlobalHotKey.clear(id: GlobalHotKey.ID.clipboard)
            return
        }
        GlobalHotKey.set(id: GlobalHotKey.ID.clipboard, keyCode: code, modifiers: mods) {
            MainActor.assumeIsolated { ClipboardPanel.shared.toggle() }
        }
    }

    static func save(code: Int, mods: Int, label: String) {
        SharedDefaults.store.set(code, forKey: "clipboardHotKeyCode")
        SharedDefaults.store.set(mods, forKey: "clipboardHotKeyMods")
        SharedDefaults.store.set(label, forKey: "clipboardHotKeyLabel")
    }
}

enum FocusDimHotKey {
    static var code: Int {
        SharedDefaults.store.object(forKey: "focusDimHotKeyCode") as? Int ?? kVK_ANSI_F
    }
    static var mods: Int {
        SharedDefaults.store.object(forKey: "focusDimHotKeyMods") as? Int ?? (cmdKey | optionKey)
    }
    static var label: String {
        SharedDefaults.store.string(forKey: "focusDimHotKeyLabel") ?? "⌥⌘F"
    }

    static func register() {
        GlobalHotKey.set(id: GlobalHotKey.ID.focusDim, keyCode: code, modifiers: mods) {
            toggleFocusDim()
        }
    }
}

func toggleFocusDim() {
    let enabled = !SharedDefaults.store.bool(forKey: "focusDimEnabled")
    SharedDefaults.store.set(enabled, forKey: "focusDimEnabled")
    IPC.post(IPC.Name.settingsChanged)
}

enum PresenterHotKey {
    static var code: Int {
        SharedDefaults.store.object(forKey: "presenterHotKeyCode") as? Int ?? kVK_ANSI_P
    }
    static var mods: Int {
        SharedDefaults.store.object(forKey: "presenterHotKeyMods") as? Int
            ?? (cmdKey | optionKey | shiftKey)
    }
    static var label: String {
        SharedDefaults.store.string(forKey: "presenterHotKeyLabel") ?? "⇧⌥⌘P"
    }

    static func register() {
        GlobalHotKey.set(id: GlobalHotKey.ID.presenterToggle, keyCode: code, modifiers: mods) {
            let d = SharedDefaults.store
            d.set(!d.bool(forKey: "presenterMode"), forKey: "presenterMode")
            IPC.post(IPC.Name.settingsChanged)
        }
    }

    static func unregister() {
        GlobalHotKey.clear(id: GlobalHotKey.ID.presenterToggle)
    }
}

func menuBarExtraStatusWindow() -> NSWindow? {
    NSApp.windows.first {
        guard $0.className.contains("StatusBarWindow"),
            let button = firstButton(in: $0.contentView)
        else { return false }
        return button.image != nil && button !== LimitsStatusItem.button
    }
}

func clickStatusItem() {
    if let statusWindow = menuBarExtraStatusWindow(),
        let button = firstButton(in: statusWindow.contentView),
        button !== LimitsStatusItem.button
    {
        button.performClick(nil)
    }
}

func togglePanel() {
    clickStatusItem()
}

private func firstButton(in view: NSView?) -> NSButton? {
    guard let view else { return nil }
    if let button = view as? NSButton { return button }
    for sub in view.subviews {
        if let found = firstButton(in: sub) { return found }
    }
    return nil
}

func centerPanelUnderIcon(_ panel: NSWindow) {
    guard let icon = menuBarExtraStatusWindow() else { return }
    var x = icon.frame.midX - panel.frame.width / 2
    if let screen = icon.screen {
        let visible = screen.visibleFrame
        x = min(max(x, visible.minX + 8), visible.maxX - panel.frame.width - 8)
    }
    guard abs(panel.frame.origin.x - x) > 0.5 else { return }
    panel.setFrameOrigin(NSPoint(x: x, y: panel.frame.origin.y))
}

func dismissPanel() {
    if NSColorPanel.shared.isVisible { NSColorPanel.shared.close() }
    guard
        NSApp.windows.contains(where: {
            $0.className.contains("MenuBarExtraWindow") && $0.isVisible
        })
    else { return }
    clickStatusItem()
}

struct TabInfo {
    let id: String
    let title: String
    let subtitle: String
    let enabledKey: String
}

let allTabs: [TabInfo] = [
    TabInfo(
        id: "usage", title: "Agent Usage",
        subtitle: "limit polling, usage stats", enabledKey: "tabUsageEnabled"),
    TabInfo(
        id: "music", title: "Music",
        subtitle: "player, media keys", enabledKey: "tabMusicEnabled"),
    TabInfo(
        id: "system", title: "System",
        subtitle: "prevent sleep, keyboard cleaning", enabledKey: "tabSystemEnabled"),
    TabInfo(
        id: "calendar", title: "Calendar",
        subtitle: "today's schedule", enabledKey: "tabCalendarEnabled"),
]

func orderedTabIDs(_ raw: String) -> [String] {
    var ids = raw.split(separator: ",").map(String.init)
        .filter { id in allTabs.contains { $0.id == id } }
    for tab in allTabs where !ids.contains(tab.id) {
        ids.append(tab.id)
    }
    return ids
}

struct RootView: View {
    @EnvironmentObject private var services: AppServices
    @State private var tab = UserDefaults.standard.string(forKey: "tab") ?? "usage"
    @AppStorage("theme", store: SharedDefaults.store) private var themeName = "accent"
    @AppStorage("tabUsageEnabled", store: SharedDefaults.store) private var usageEnabled = true
    @AppStorage("tabMusicEnabled", store: SharedDefaults.store) private var musicEnabled = true
    @AppStorage("tabSystemEnabled", store: SharedDefaults.store) private var systemEnabled = true
    @AppStorage("tabCalendarEnabled", store: SharedDefaults.store) private var calendarEnabled =
        true
    @AppStorage("focusDimEnabled", store: SharedDefaults.store) private var focusDimEnabled = false
    @AppStorage("tabOrder", store: SharedDefaults.store) private var tabOrderRaw =
        "usage,music,system"
    @AppStorage("mainWindowSection", store: SharedDefaults.store) private var mainWindowSection =
        "dashboard"
    @AppStorage("settingsSection", store: SharedDefaults.store) private var settingsSection =
        "general"
    @StateObject private var permissions = PermissionsModel.shared
    @StateObject private var presenterState = PresenterState.shared
    @State private var showDeveloper = false

    private var enabledTabs: [(id: String, title: String)] {
        orderedTabIDs(tabOrderRaw).compactMap { id in
            guard let info = allTabs.first(where: { $0.id == id }) else { return nil }
            let on =
                switch id {
                case "usage": usageEnabled
                case "music": musicEnabled
                case "system": systemEnabled
                case "calendar": calendarEnabled
                default: false
                }
            return on ? (info.id, info.title) : nil
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                Image(nsImage: Logo.header)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 19, height: 19)
                Text("EDITH")
                    .font(.system(size: 12, weight: .semibold))
                    .tracking(3)
                    .foregroundStyle(.secondary)
                Spacer()
                if tab == "music", musicEnabled {
                    Button {
                        try? FileManager.default.createDirectory(
                            at: Repo.musicDir, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(Repo.musicDir)
                        dismissPanel()
                    } label: {
                        Image(systemName: "folder")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(HoverButtonStyle())
                    .help("Open music folder in Finder")
                }
                Button {
                    toggleFocusDim()
                } label: {
                    Image(systemName: focusDimEnabled ? "circle.lefthalf.filled" : "circle.dashed")
                        .font(.system(size: 13))
                        .foregroundStyle(focusDimEnabled ? .primary : .secondary)
                }
                .buttonStyle(HoverButtonStyle())
                .help("Focus dim (\(FocusDimHotKey.label))")
                Button {
                    mainWindowSection = "settings"
                    MainApp.openDashboard()
                    dismissPanel()
                } label: {
                    Image(
                        systemName: permissions.needsAttention
                            ? "exclamationmark.triangle.fill" : "checkmark.shield"
                    )
                    .font(.system(size: 13))
                    .foregroundStyle(
                        permissions.needsAttention
                            ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                }
                .buttonStyle(HoverButtonStyle())
                .help(permissions.needsAttention ? "Permissions need attention" : "Permissions")
                Button {
                    if NSApp.currentEvent?.modifierFlags.contains(.option) == true {
                        showDeveloper.toggle()
                    } else {
                        mainWindowSection = "settings"
                        settingsSection = "general"
                        MainApp.openDashboard()
                        dismissPanel()
                    }
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(HoverButtonStyle())
                .help("Settings (⌥-click for developer options)")
                Menu {
                    Button("Close Panel") { dismissPanel() }
                    Button("Quit Edith Completely", role: .destructive) {
                        IPC.post(IPC.Name.quitMainApp)
                        NSApp.terminate(nil)
                    }
                } label: {
                    Image(systemName: "power")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .menuIndicator(.hidden)
                .buttonStyle(HoverButtonStyle())
                .help("Quit options")
            }
            if presenterState.autoActive {
                presenterBanner
            }
            if enabledTabs.count > 1 {
                TabBar(tabs: enabledTabs, selection: $tab, theme: themeColor(themeName))
            }
            if tab == "usage", let store = services.usage {
                UsageView().environmentObject(store)
            } else if tab == "music", let player = services.music {
                MusicView().environmentObject(player)
            } else if tab == "system", let system = services.system {
                SystemView().environmentObject(system)
            } else if tab == "calendar", let calendar = services.calendar {
                CalendarView().environmentObject(calendar)
            } else if enabledTabs.isEmpty {
                Text("All tabs are off - enable one in Edith's settings (⚙)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 28)
            }
            if showDeveloper {
                DeveloperPanel()
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: tab)
        .onAppear {
            pinTab()
            permissions.refresh()
            MiniPanel.shared.services = services
            MiniPanel.shared.tab = tab
            MiniPanel.shared.sync()
        }
        .onChange(of: tab) {
            UserDefaults.standard.set(tab, forKey: "tab")
            MiniPanel.shared.tab = tab
            MiniPanel.shared.expectResize()
            MiniPanel.shared.sync()
            settleMiniPanel()
        }
        .onChange(of: usageEnabled) { pinTab() }
        .onChange(of: musicEnabled) { pinTab() }
        .onChange(of: systemEnabled) { pinTab() }
        .onChange(of: calendarEnabled) { pinTab() }
        .padding(14)
        .frame(width: 480)
        .background(PanelBackground())
        .onExitCommand { dismissPanel() }
    }

    private var presenterBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "eye.fill")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
            Text(presenterState.autoReason ?? "Screen sharing detected")
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
            Spacer(minLength: 8)
            Button("Pause") {
                services.presenter?.pauseUntilShareEnds()
            }
            .buttonStyle(HoverButtonStyle())
            .font(.system(size: 11))
            .help("Stop auto-blur until this share ends")
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    private func settleMiniPanel() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            MiniPanel.shared.sync()
        }
    }

    private func pinTab() {
        if !enabledTabs.contains(where: { $0.id == tab }), let first = enabledTabs.first {
            tab = first.id
        }
    }
}

private struct PanelBackground: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        (scheme == .dark ? Color.black.opacity(0.55) : Color.white.opacity(0.45))
            .ignoresSafeArea()
    }
}
