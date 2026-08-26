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
        let hosting = NSHostingController(
            rootView: HerdrDetachedView(store: store, tab: tab, launchEnabled: launchEnabled))
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
    let tab: HerdrOpenTab
    let launchEnabled: Bool

    var body: some View {
        HerdrSessionView(store: store, tab: tab, launchEnabled: launchEnabled)
            .environment(\.terminalLaunchEnabled, launchEnabled)
    }
}
