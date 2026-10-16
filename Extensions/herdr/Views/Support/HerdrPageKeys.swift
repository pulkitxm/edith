import AppKit
import EdithExtensionUI

enum HerdrPageWindowKind {
    case main
    case detached
    case other

    static func of(_ window: NSWindow?) -> HerdrPageWindowKind {
        guard let raw = window?.identifier?.rawValue else { return .other }
        if raw == "EdithMainWindow" { return .main }
        if raw.hasPrefix("EdithSection.") { return .detached }
        return .other
    }
}

extension HerdrStore {
    func hostsPage(_ window: NSWindow?) -> Bool {
        guard let window else { return false }
        return pageWindows.contains(window)
    }

    func performPageKey(
        characters: String?, keyCode: UInt16, modifiers: NSEvent.ModifierFlags, repeats: Bool,
        in window: NSWindow?
    ) -> Bool {
        guard hostsPage(window) else { return false }
        let flags = modifiers.chordOnly
        let kind = HerdrPageWindowKind.of(window)
        if flags == .command, characters?.lowercased() == "k",
            SessionSearchCommand.perform(in: window, store: self, sessionsOnScreen: { true })
        {
            return true
        }
        if performLayoutKey(keyCode: keyCode, modifiers: modifiers, in: window) { return true }
        if HerdrAgentDetailCommand.perform(
            characters: characters, modifiers: modifiers, repeats: repeats, in: window,
            store: self, sessionsOnScreen: { true })
        {
            return true
        }
        if kind == .main,
            performTerminalPanelKey(
                keyCode: keyCode, characters: characters, modifiers: modifiers)
        {
            return true
        }
        if keyCode == 48, flags.contains(.control), !flags.contains(.command) {
            return cycleTab(backwards: flags.contains(.shift))
        }
        if kind == .main, flags == .command, characters?.lowercased() == "w" {
            _ = closeFocusedTab()
            return true
        }
        return false
    }

    func performSceneKey(
        characters: String?, modifiers: NSEvent.ModifierFlags, repeats: Bool,
        in window: NSWindow?, surface: HerdrAgentDetailSurface
    ) -> Bool {
        guard hostsPage(window),
            HerdrAgentDetailCommand.matches(
                characters: characters, modifiers: modifiers),
            HerdrAgentDetailCommand.applies(to: surface, sessionsOnScreen: true)
        else { return false }
        if !repeats { toggleAgentDetails() }
        return true
    }
}

@MainActor
final class HerdrPageKeyMonitor {
    private var monitor: Any?
    var active = false

    func install(
        store: HerdrStore,
        handle: @escaping @MainActor (HerdrStore, NSEvent, NSWindow?) -> Bool
    ) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self, weak store] event in
            let handled = MainActor.assumeIsolated {
                guard let self, self.active, let store else { return false }
                return handle(store, event, NSApp.keyWindow)
            }
            return handled ? nil : event
        }
    }

    func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
