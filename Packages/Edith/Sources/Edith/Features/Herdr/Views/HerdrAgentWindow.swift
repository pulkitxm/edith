import AppKit
import EdithKit
import SwiftUI

@MainActor
enum HerdrAgentWindow {
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
                .frame(width: 228, height: 28)
                .padding(.trailing, 8)
        )
        hosting.frame = NSRect(x: 0, y: 0, width: 236, height: 28)
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

    private var selection: Binding<HerdrAgentView> {
        Binding(
            get: { store.detachedTab(id: agentID)?.view ?? .agent },
            set: { store.setView($0, for: agentID) })
    }

    var body: some View {
        Picker("View", selection: selection) {
            ForEach([HerdrAgentView.agent, .split, .diff], id: \.self) { mode in
                Label(mode.shortTitle, systemImage: mode.icon)
                    .tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .controlSize(.small)
        .labelsHidden()
        .help("Choose the agent, split, or diff view")
    }
}
