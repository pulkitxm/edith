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

    func performSpaceKey(
        characters: String?, keyCode: UInt16, modifiers: NSEvent.ModifierFlags,
        in window: NSWindow?, spaceID: String
    ) -> Bool {
        guard hostsPage(window), let model = uiSpaces[spaceID],
            let command = HerdrSpaceKeyCommand.resolve(
                characters: characters, keyCode: keyCode, modifiers: modifiers)
        else { return false }
        switch command {
        case .newTerminal: _ = model.addTerminal()
        case .splitRight: model.split(.right)
        case .splitDown: model.split(.bottom)
        case .closeTab:
            if !model.closeSelectedTab() { window?.performClose(nil) }
        case .closePane: _ = model.closeFocusedPane()
        case let .selectTab(number): _ = model.selectTab(number: number)
        case .nextTab: _ = model.cycleTab(backwards: false)
        case .previousTab: _ = model.cycleTab(backwards: true)
        }
        return true
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
                return handle(store, event, event.window ?? NSApp.keyWindow)
            }
            return handled ? nil : event
        }
    }

    func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
