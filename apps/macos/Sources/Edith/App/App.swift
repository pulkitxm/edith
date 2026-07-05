import Carbon.HIToolbox
import SwiftUI

enum Repo {
    static let root: URL = {
        let override = UserDefaults.standard.string(forKey: "repoPath")
        return URL(fileURLWithPath: override ?? "/Users/pulkit/scripts/edith")
    }()
    static var dashboard: URL { root.appendingPathComponent("apps/dashboard/dashboard.html") }
    static var usageJSON: URL { root.appendingPathComponent("apps/dashboard/data/usage.json") }
    static var ccUpdate: URL { root.appendingPathComponent("apps/dashboard/cc-update") }
    static var musicDir: URL { root.appendingPathComponent("local/music") }
}

func applyAppearance(_ value: String) {
    let app = NSApplication.shared
    switch value {
    case "light": app.appearance = NSAppearance(named: .aqua)
    case "dark": app.appearance = NSAppearance(named: .darkAqua)
    default: app.appearance = nil
    }
}

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
    return AppServices()
}

@main
struct EdithApp: App {
    private let services = migratedServices()

    init() {
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
        SettingsBackup.shared.start()
        applyAppearance(UserDefaults.standard.string(forKey: "appearance") ?? "system")

        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53, !ShortcutRecorder.isRecording,
                !NSColorPanel.shared.isVisible,
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

enum HotKey {
    private static var ref: EventHotKeyRef?
    private static var handlerInstalled = false

    static var code: Int {
        UserDefaults.standard.object(forKey: "hotKeyCode") as? Int ?? kVK_ANSI_E
    }
    static var mods: Int {
        UserDefaults.standard.object(forKey: "hotKeyMods") as? Int ?? (cmdKey | optionKey)
    }
    static var label: String {
        UserDefaults.standard.string(forKey: "hotKeyLabel") ?? "⌥⌘E"
    }

    static func register() {
        if !handlerInstalled {
            var eventType = EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(
                GetApplicationEventTarget(),
                { _, _, _ in
                    DispatchQueue.main.async { togglePanel() }
                    return noErr
                }, 1, &eventType, nil, nil)
            handlerInstalled = true
        }
        unregister()
        let id = EventHotKeyID(signature: OSType(0x4544_4954), id: 1)
        RegisterEventHotKey(
            UInt32(code), UInt32(mods), id, GetApplicationEventTarget(), 0, &ref)
    }

    static func unregister() {
        if let ref {
            UnregisterEventHotKey(ref)
            Self.ref = nil
        }
    }

    static func save(code: Int, mods: Int, label: String) {
        UserDefaults.standard.set(code, forKey: "hotKeyCode")
        UserDefaults.standard.set(mods, forKey: "hotKeyMods")
        UserDefaults.standard.set(label, forKey: "hotKeyLabel")
    }
}

private func menuBarExtraStatusWindow() -> NSWindow? {
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

struct HoverButton: ViewModifier {
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .padding(4)
            .background(
                .primary.opacity(hovering ? 0.07 : 0), in: RoundedRectangle(cornerRadius: 6)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(.primary.opacity(hovering ? 0.18 : 0), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(hovering ? 0.35 : 0), radius: 4, y: 1)
            .onHover { hovering = $0 }
            .pointerCursor()
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

struct HoverButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .modifier(HoverButton())
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

extension View {
    func hoverButton() -> some View { modifier(HoverButton()) }

    @ViewBuilder
    func pointerCursor() -> some View {
        if #available(macOS 15.0, *) {
            pointerStyle(.link)
        } else {
            onContinuousHover { phase in
                if case .active = phase {
                    NSCursor.pointingHand.set()
                } else {
                    NSCursor.arrow.set()
                }
            }
        }
    }

    func presenterBlur(_ on: Bool) -> some View {
        blur(radius: on ? 4 : 0)
    }

    func card() -> some View {
        padding(13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
    }
}

func eyebrow(_ text: String) -> some View {
    Text(text)
        .font(.system(size: 10, weight: .semibold))
        .tracking(1.4)
        .foregroundStyle(.tertiary)
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
    @AppStorage("theme") private var themeName = "accent"
    @AppStorage("tabUsageEnabled") private var usageEnabled = true
    @AppStorage("tabMusicEnabled") private var musicEnabled = true
    @AppStorage("tabSystemEnabled") private var systemEnabled = true
    @AppStorage("tabCalendarEnabled") private var calendarEnabled = true
    @AppStorage("tabOrder") private var tabOrderRaw = "usage,music,system"
    @State private var showSettings = false

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
                Text(showSettings ? "EDITH · SETTINGS" : "EDITH")
                    .font(.system(size: 12, weight: .semibold))
                    .tracking(3)
                    .foregroundStyle(.secondary)
                Spacer()
                if tab == "music", musicEnabled, !showSettings {
                    Button {
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
                    withAnimation(.easeOut(duration: 0.15)) { showSettings.toggle() }
                } label: {
                    Image(systemName: showSettings ? "gearshape.fill" : "gearshape")
                        .font(.system(size: 13))
                        .foregroundStyle(showSettings ? themeColor(themeName) : Color.secondary)
                }
                .buttonStyle(HoverButtonStyle())
                .help(showSettings ? "Back" : "Settings")
                Button {
                    NSApp.terminate(nil)
                } label: {
                    Image(systemName: "power")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(HoverButtonStyle())
                .keyboardShortcut("q", modifiers: .command)
                .help("Quit Edith (⌘Q)")
            }
            if showSettings {
                ScrollView {
                    SettingsView()
                }
                .frame(height: 640)
            } else {
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
                    Text("All tabs are off - enable one in Settings (⚙)")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 28)
                }
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: tab)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: showSettings)
        .onAppear {
            pinTab()
            MiniPanel.shared.services = services
            MiniPanel.shared.tab = tab
            MiniPanel.shared.showSettings = showSettings
            MiniPanel.shared.sync()
        }
        .onChange(of: tab) {
            UserDefaults.standard.set(tab, forKey: "tab")
            MiniPanel.shared.tab = tab
            MiniPanel.shared.expectResize()
            MiniPanel.shared.sync()
            settleMiniPanel()
        }
        .onChange(of: showSettings) {
            MiniPanel.shared.showSettings = showSettings
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
