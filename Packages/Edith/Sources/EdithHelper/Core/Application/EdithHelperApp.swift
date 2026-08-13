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
func migratedServices() -> AppServices {
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
    ExtensionDefaultsMigration.migrate()
    Repo.prepareStoredPaths()
    return AppServices()
}

final class MenuBarAppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        if anEarlierInstanceIsRunning() { exit(0) }
        NSApp.setActivationPolicy(.accessory)
        ProcessInfo.processInfo.disableAutomaticTermination("Edith lives in the menu bar")
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        PanelController.shared = PanelController(services: AppState.services)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

private func anEarlierInstanceIsRunning() -> Bool {
    guard let id = Bundle.main.bundleIdentifier else { return false }
    let me = NSRunningApplication.current.processIdentifier
    return NSRunningApplication.runningApplications(withBundleIdentifier: id)
        .contains { $0.processIdentifier < me }
}

@main
struct EdithApp: App {
    @NSApplicationDelegateAdaptor(MenuBarAppDelegate.self) private var appDelegate

    init() {
        _ = ProcessUptime.launchedAt

        NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { _ in
            dismissPanel()
        }
        HotKey.register()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            SettingsBackup.shared.start()
        }
        DispatchQueue.global(qos: .utility).async {
            CLIInstaller.installIfNeeded()
        }
        applyAppearance(
            SharedDefaults.store.string(forKey: AppStorageKeys.General.appearance) ?? "system")
        let services = AppState.services
        _ = IPC.observe(IPC.Name.settingsChanged) {
            HotKey.register()
            SettingsBackup.shared.settingsDidChange()
            applyAppearance(
                SharedDefaults.store.string(forKey: AppStorageKeys.General.appearance) ?? "system")
            services.sync()
        }
        _ = IPC.observe(IPC.Name.presenterAutoActiveChanged) {
            services.usage?.refreshMenuBarItem()
        }
        _ = IPC.observe(IPC.Name.permissionHintDue) {
            services.notchShelf?.postAlert(
                NotchAlert(
                    id: "permissions.hint", icon: "hand.raised.fill",
                    title: "Grant access in one place",
                    subtitle: "Settings > Permissions lists every one", priority: .high,
                    autoHide: 6, settingsTab: "permissions"))
        }
        _ = IPC.observe(IPC.Name.updateReadyToInstall) { info in
            guard let version = UpdateNotifier.version(from: info) else { return }
            services.notchShelf?.postAlert(UpdateNotifier.alert(for: version))
            UpdateNotifier.notify(version: version)
        }
        _ = IPC.observe(IPC.Name.requestKeyboardClean) {
            services.system?.beginCleaning()
        }
        _ = IPC.observe(
            IPC.Name.requestQuitApps,
            info: { info in
                let force = info["force"] as? Bool ?? false
                if info["all"] as? Bool == true {
                    RunningApps.quitEverythingElse(force: force)
                    return
                }
                guard let pid = info["pid"] as? Int else { return }
                RunningApps.quit(pid: pid_t(pid), force: force)
            })
        _ = IPC.observe(IPC.Name.openPanel) {
            showPanel()
        }
        _ = IPC.observe(IPC.Name.presenterPauseAuto) {
            services.presenter?.pauseUntilShareEnds()
        }
        _ = IPC.observe(IPC.Name.requestCalendarEvents) {
            Task { @MainActor in
                guard let store = services.calendar else {
                    IPC.post(
                        IPC.Name.calendarEvents,
                        userInfo: [CalendarEventBridge.statusKey: "extensionOff"])
                    return
                }
                guard store.authStatus == .fullAccess else {
                    IPC.post(
                        IPC.Name.calendarEvents,
                        userInfo: [CalendarEventBridge.statusKey: "notAuthorized"])
                    return
                }
                let events = await store.refreshAndWait()
                IPC.post(
                    IPC.Name.calendarEvents,
                    userInfo: [
                        CalendarEventBridge.statusKey: "ok",
                        CalendarEventBridge.payloadKey: CalendarEventBridge.encode(
                            CalendarEventBridge.payloads(events)),
                    ])
            }
        }
        _ = IPC.observe(IPC.Name.requestTestNotification) {
            Task { _ = await services.usage?.notifier.sendTest() }
        }
        PermissionsModel.shared.startIPCBridge()
        PermissionsModel.shared.refresh()

        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53, !NSColorPanel.shared.isVisible,
                PanelController.shared?.isOpen == true
            {
                dismissPanel()
                return nil
            }
            return event
        }
    }

    var body: some Scene {
        Settings {
            EmptyView()
        }
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
        static let micMute: UInt32 = 6
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
        SharedDefaults.store.object(forKey: AppStorageKeys.General.hotKeyCode) as? Int
            ?? kVK_ANSI_E
    }
    static var mods: Int {
        SharedDefaults.store.object(forKey: AppStorageKeys.General.hotKeyMods) as? Int
            ?? (cmdKey | optionKey)
    }
    static var label: String {
        SharedDefaults.store.string(forKey: AppStorageKeys.General.hotKeyLabel) ?? "⌥⌘E"
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
        SharedDefaults.store.set(code, forKey: AppStorageKeys.General.hotKeyCode)
        SharedDefaults.store.set(mods, forKey: AppStorageKeys.General.hotKeyMods)
        SharedDefaults.store.set(label, forKey: AppStorageKeys.General.hotKeyLabel)
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
        let enabled =
            SharedDefaults.store.object(forKey: AppStorageKeys.Clipboard.enabled) as? Bool ?? false
        guard enabled else {
            GlobalHotKey.clear(id: GlobalHotKey.ID.clipboard)
            return
        }
        GlobalHotKey.set(id: GlobalHotKey.ID.clipboard, keyCode: code, modifiers: mods) {
            MainActor.assumeIsolated { ClipboardPanel.shared.toggle() }
        }
    }

    static func unregister() {
        GlobalHotKey.clear(id: GlobalHotKey.ID.clipboard)
    }

    static func save(code: Int, mods: Int, label: String) {
        SharedDefaults.store.set(code, forKey: "clipboardHotKeyCode")
        SharedDefaults.store.set(mods, forKey: "clipboardHotKeyMods")
        SharedDefaults.store.set(label, forKey: "clipboardHotKeyLabel")
    }
}

enum MicHotKey {
    static var code: Int {
        SharedDefaults.store.object(forKey: "micHotKeyCode") as? Int ?? kVK_ANSI_M
    }
    static var mods: Int {
        SharedDefaults.store.object(forKey: "micHotKeyMods") as? Int ?? (cmdKey | shiftKey)
    }
    static var label: String {
        SharedDefaults.store.string(forKey: "micHotKeyLabel") ?? "⌘⇧M"
    }

    static func register() {
        let enabled = SharedDefaults.store.bool(forKey: AppStorageKeys.Mic.muteEnabled)
        guard enabled else {
            GlobalHotKey.clear(id: GlobalHotKey.ID.micMute)
            return
        }
        GlobalHotKey.set(id: GlobalHotKey.ID.micMute, keyCode: code, modifiers: mods) {
            MainActor.assumeIsolated { AppState.services.micMute?.toggle() }
        }
    }

    static func unregister() {
        GlobalHotKey.clear(id: GlobalHotKey.ID.micMute)
    }

    static func save(code: Int, mods: Int, label: String) {
        SharedDefaults.store.set(code, forKey: "micHotKeyCode")
        SharedDefaults.store.set(mods, forKey: "micHotKeyMods")
        SharedDefaults.store.set(label, forKey: "micHotKeyLabel")
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
        guard SharedDefaults.store.bool(forKey: FocusDimState.enabledKey) else {
            unregister()
            return
        }
        GlobalHotKey.set(id: GlobalHotKey.ID.focusDim, keyCode: code, modifiers: mods) {
            toggleFocusDim()
        }
    }

    static func unregister() {
        GlobalHotKey.clear(id: GlobalHotKey.ID.focusDim)
    }
}

func toggleFocusDim() {
    let active = !SharedDefaults.store.bool(forKey: FocusDimState.activeKey)
    SharedDefaults.store.set(active, forKey: FocusDimState.activeKey)
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
        let enabled =
            SharedDefaults.store.object(forKey: AppStorageKeys.Presenter.enabled) as? Bool ?? false
        guard enabled else {
            GlobalHotKey.clear(id: GlobalHotKey.ID.presenterToggle)
            return
        }
        GlobalHotKey.set(id: GlobalHotKey.ID.presenterToggle, keyCode: code, modifiers: mods) {
            let d = SharedDefaults.store
            let enabled = !d.bool(forKey: AppStorageKeys.Presenter.mode)
            d.set(enabled, forKey: AppStorageKeys.Presenter.mode)
            if !enabled { IPC.post(IPC.Name.presenterPauseAuto) }
            IPC.post(IPC.Name.settingsChanged)
        }
    }

    static func unregister() {
        GlobalHotKey.clear(id: GlobalHotKey.ID.presenterToggle)
    }
}

func togglePanel() {
    MainActor.assumeIsolated { PanelController.shared?.toggle() }
}

func showPanel() {
    MainActor.assumeIsolated { MainApp.openDashboard() }
}

func dismissPanel() {
    MainActor.assumeIsolated {
        if NSColorPanel.shared.isVisible { NSColorPanel.shared.close() }
        PanelController.shared?.close()
    }
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
        subtitle: "limit polling, usage stats", enabledKey: AppStorageKeys.Tabs.usageEnabled),
    TabInfo(
        id: "music", title: "Music",
        subtitle: "player, media keys", enabledKey: AppStorageKeys.Tabs.musicEnabled),
    TabInfo(
        id: "system", title: "System",
        subtitle: "prevent sleep, keyboard cleaning", enabledKey: AppStorageKeys.Tabs.systemEnabled),
    TabInfo(
        id: "calendar", title: "Calendar",
        subtitle: "today's schedule", enabledKey: AppStorageKeys.Tabs.calendarEnabled),
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
    let services: AppServices

    init(services: AppServices) {
        self.services = services
    }

    @State private var tab =
        UserDefaults.standard.string(forKey: AppStorageKeys.General.panelTab) ?? "usage"
    @AppStorage(AppStorageKeys.General.theme, store: SharedDefaults.store) private var themeName =
        "accent"
    @AppStorage(AppStorageKeys.Tabs.usageEnabled, store: SharedDefaults.store) private
        var usageEnabled = false
    @AppStorage(AppStorageKeys.Tabs.musicEnabled, store: SharedDefaults.store) private
        var musicEnabled = false
    @AppStorage(AppStorageKeys.Tabs.systemEnabled, store: SharedDefaults.store) private
        var systemEnabled = false
    @AppStorage(AppStorageKeys.Tabs.calendarEnabled, store: SharedDefaults.store) private
        var calendarEnabled =
        false
    @AppStorage(FocusDimState.enabledKey, store: SharedDefaults.store) private var focusDimEnabled =
        false
    @AppStorage(AppStorageKeys.Presenter.enabled, store: SharedDefaults.store) private
        var presenterEnabled =
        false
    @AppStorage(AppStorageKeys.Tabs.order, store: SharedDefaults.store) private var tabOrderRaw =
        "usage,music,system"
    @AppStorage(AppStorageKeys.General.mainWindowSection, store: SharedDefaults.store) private
        var mainWindowSection =
        "dashboard"
    private var permissions = PermissionsModel.shared
    private var presenterState = PresenterState.shared
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
                Button {
                    MainApp.openDashboard()
                    dismissPanel()
                } label: {
                    HStack(spacing: 10) {
                        Image(nsImage: Logo.header)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 19, height: 19)
                        Text("EDITH")
                            .font(.system(size: 12, weight: .semibold))
                            .tracking(3)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(HoverButtonStyle())
                .pointerCursor()
                .help("Open the Edith app")
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
                if let colorPicker = services.colorPicker {
                    Button {
                        dismissPanel()
                        colorPicker.pick()
                    } label: {
                        Image(systemName: "eyedropper")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(HoverButtonStyle())
                    .help("Grab a color (\(ColorPickerHotKey.label))")
                    .contextMenu {
                        if colorPicker.history.isEmpty {
                            Text("No colors picked yet")
                        } else {
                            ForEach(colorPicker.history.prefix(8)) { swatch in
                                Button(swatch.string(for: .hex)) { colorPicker.copyDefault(swatch) }
                            }
                        }
                    }
                }
                if focusDimEnabled {
                    Button {
                        toggleFocusDim()
                    } label: {
                        Image(systemName: "circle.lefthalf.filled")
                            .font(.system(size: 13))
                            .foregroundStyle(.primary)
                    }
                    .buttonStyle(HoverButtonStyle())
                    .help("Focus dim (\(FocusDimHotKey.label))")
                }
                Button {
                    mainWindowSection = "extensions"
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
                        MainApp.openSettings()
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
            if presenterEnabled, presenterState.autoActive {
                presenterBanner
            }
            if let player = services.music, player.current != nil {
                NowPlayingBar(player: player, theme: themeColor(themeName))
            }
            if enabledTabs.count > 1 {
                TabBar(tabs: enabledTabs, selection: $tab, theme: themeColor(themeName))
            }
            ZStack {
                tabBody
                    .id(tab)
                    .transition(.opacity)
            }
            .animation(.easeInOut(duration: 0.22), value: tab)
            if showDeveloper {
                DeveloperPanel(services: services)
            }
        }
        .tint(themeColor(themeName))
        .onAppear {
            pinTab()
            permissions.refresh()
        }
        .onChange(of: tab) {
            UserDefaults.standard.set(tab, forKey: AppStorageKeys.General.panelTab)
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

    @ViewBuilder
    private var tabBody: some View {
        if tab == "usage", let store = services.usage {
            UsageView(store: store)
        } else if tab == "music", let player = services.music {
            MusicView(player: player)
        } else if tab == "system", let system = services.system {
            SystemView().environment(system)
        } else if tab == "calendar", let calendar = services.calendar {
            CalendarView().environment(calendar)
        } else if enabledTabs.isEmpty {
            Text("All tabs are off - enable one in Edith's settings (⚙)")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.vertical, 28)
        }
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
