import AppKit
import EdithKit
import SwiftUI

@MainActor
enum HerdrAgentWindow {
    static let viewControlsContentWidth = 262.0
    static let viewControlsWidth = 270.0
    private static var windows: [String: NSWindow] = [:]

    static var openIDs: Set<String> { Set(windows.keys) }

    static func has(_ id: String) -> Bool { windows[id] != nil }

    static func raise(_ id: String) -> Bool {
        guard let window = windows[id] else { return false }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return true
    }

    static func open(agent: HerdrAgent, store: HerdrStore, launchEnabled: Bool) {
        if raise(agent.id) { return }
        let tab = store.detachedTab(for: agent)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 640),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false)
        window.title =
            agent.isTerminal
            ? "\(HerdrMachineTerminal.title) · \(agent.machineName)"
            : "\(agent.title) · \(agent.machineName)"
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 560, height: 360)
        window.tabbingMode = .disallowed
        if !agent.isTerminal {
            addViewControls(to: window, store: store, agentID: agent.id)
        }
        let hosting = NSHostingController(
            rootView: HerdrDetachedView(
                store: store, agentID: tab.id, launchEnabled: launchEnabled))
        hosting.sizingOptions = []
        window.contentViewController = hosting
        window.setContentSize(NSSize(width: 1000, height: 640))
        window.setFrameAutosaveName("EdithHerdrAgentWindow")
        if window.frame.origin == .zero { window.center() }
        window.delegate = HerdrAgentWindowDelegate.shared
        windows[agent.id] = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    static func addViewControls(
        to window: NSWindow, store: HerdrStore, agentID: String
    ) {
        let accessory = NSTitlebarAccessoryViewController()
        accessory.layoutAttribute = .right
        let hosting = NSHostingView(
            rootView: HerdrTitlebarViewPicker(store: store, agentID: agentID)
                .frame(width: viewControlsContentWidth, height: 28)
                .padding(.trailing, 8)
        )
        hosting.frame = NSRect(x: 0, y: 0, width: viewControlsWidth, height: 28)
        accessory.view = hosting
        window.addTitlebarAccessoryViewController(accessory)
    }

    static func forget(_ window: NSWindow) -> String? {
        guard let id = windows.first(where: { $0.value === window })?.key else { return nil }
        windows.removeValue(forKey: id)
        return id
    }
}

@MainActor
final class HerdrAgentWindowDelegate: NSObject, NSWindowDelegate {
    static let shared = HerdrAgentWindowDelegate()

    var onClose: ((String) -> Void)?

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        guard let id = HerdrAgentWindow.forget(window) else { return }
        onClose?(id)
    }
}

private struct HerdrDetachedView: View {
    let store: HerdrStore
    let agentID: String
    let launchEnabled: Bool

    var body: some View {
        if let tab = store.detachedTab(id: agentID) {
            HerdrSessionView(store: store, tab: tab, launchEnabled: launchEnabled)
                .environment(\.terminalLaunchEnabled, launchEnabled)
        }
    }
}

struct HerdrTitlebarViewPicker: View {
    let store: HerdrStore
    let agentID: String

    @AppStorage(AppStorageKeys.General.theme, store: SharedDefaults.store) private var themeName =
        AppTheme.accent.rawValue
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var selection: HerdrAgentView {
        store.detachedTab(id: agentID)?.view ?? .agent
    }

    private var theme: AppTheme { AppTheme(storedName: themeName) }
    private var dark: Bool { scheme == .dark }
    private var accent: Color { DashSkin.accent(dark, theme: theme) }

    var body: some View {
        HStack(spacing: UIScale.pt(6)) {
            HStack(spacing: UIScale.pt(2)) {
                ForEach([HerdrAgentView.agent, .split, .diff], id: \.self) { mode in
                    HerdrTitlebarViewButton(
                        mode: mode,
                        selected: selection == mode,
                        dark: dark,
                        theme: theme
                    ) {
                        store.setView(mode, for: agentID)
                    }
                }
            }
            .padding(UIScale.pt(2))
            .frame(width: UIScale.pt(228))
            .widgetBar(
                cornerRadius: 8,
                fill: DashSkin.paper(dark, theme: theme),
                stroke: accent.opacity(dark ? 0.5 : 0.35)
            )
            Button {
                withAnimation(Motion.animation(Motion.glide, reduceMotion: reduceMotion)) {
                    store.detailOpen.toggle()
                }
            } label: {
                Image(systemName: "sidebar.right")
                    .font(.system(size: UIScale.pt(11), weight: .semibold))
                    .foregroundStyle(DashSkin.ink(dark, theme: theme).opacity(0.72))
                    .frame(width: UIScale.pt(22), height: UIScale.pt(22))
                    .padding(UIScale.pt(2))
                    .widgetBar(
                        cornerRadius: 8,
                        fill: store.detailOpen
                            ? accent.opacity(dark ? 0.24 : 0.16)
                            : DashSkin.paper(dark, theme: theme),
                        stroke: accent.opacity(dark ? 0.5 : 0.35)
                    )
            }
            .buttonStyle(.edith(.borderless, selected: store.detailOpen, tint: accent))
            .help(store.detailOpen ? "Hide details" : "Show details")
            .accessibilityLabel(store.detailOpen ? "Hide details" : "Show details")
        }
        .tint(accent)
    }
}

private struct HerdrTitlebarViewButton: View {
    let mode: HerdrAgentView
    let selected: Bool
    let dark: Bool
    let theme: AppTheme
    let select: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false

    private var accent: Color { DashSkin.accent(dark, theme: theme) }
    private var foreground: Color {
        selected ? accent : DashSkin.ink(dark, theme: theme).opacity(hovered ? 0.92 : 0.68)
    }

    var body: some View {
        Button(action: select) {
            Label(mode.shortTitle, systemImage: mode.icon)
                .font(.system(size: UIScale.pt(10), weight: selected ? .semibold : .medium))
                .foregroundStyle(foreground)
                .padding(.horizontal, UIScale.pt(7))
                .frame(maxWidth: .infinity, minHeight: UIScale.pt(22))
                .background(
                    selected
                        ? accent.opacity(dark ? 0.24 : 0.16)
                        : accent.opacity(hovered ? (dark ? 0.12 : 0.08) : 0),
                    in: RoundedRectangle(cornerRadius: UIScale.pt(6))
                )
                .overlay {
                    RoundedRectangle(cornerRadius: UIScale.pt(6))
                        .strokeBorder(
                            accent.opacity(selected ? (dark ? 0.78 : 0.62) : 0),
                            lineWidth: UIScale.pt(1))
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.edith(.borderless, selected: selected, tint: accent))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help(mode.title)
        .onHover { hovered = $0 }
        .animation(Motion.animation(Motion.feedback, reduceMotion: reduceMotion), value: hovered)
        .animation(Motion.animation(Motion.feedback, reduceMotion: reduceMotion), value: selected)
    }
}
