import AppKit
import EdithKit

extension NSEvent.ModifierFlags {
    public var chordOnly: NSEvent.ModifierFlags {
        intersection([.command, .option, .control, .shift])
    }
}

enum WindowTabKeyCommand: Equatable {
    case selectTab(index: Int)
    case nextTab
    case previousTab

    static func resolve(
        characters: String?, keyCode: UInt16, modifiers: NSEvent.ModifierFlags, tabbed: Bool
    ) -> WindowTabKeyCommand? {
        guard tabbed else { return nil }
        let flags = modifiers.chordOnly
        if keyCode == 48, flags.contains(.control), !flags.contains(.command) {
            return flags.contains(.shift) ? .previousTab : .nextTab
        }
        guard flags == .command, let characters, let value = Int(characters), value >= 1,
            value <= 9
        else { return nil }
        return .selectTab(index: value - 1)
    }
}

enum WorkspaceKeyCommand: Equatable {
    case nextPaneTab
    case previousPaneTab
    case nextPane
    case previousPane
    case nextTerminalTab
    case previousTerminalTab

    static func resolve(
        characters: String?, keyCode: UInt16, modifiers: NSEvent.ModifierFlags
    ) -> WorkspaceKeyCommand? {
        let flags = modifiers.chordOnly
        if flags == [.command, .option] {
            if keyCode == 124 { return .nextPaneTab }
            if keyCode == 123 { return .previousPaneTab }
        }
        if flags == [.command, .control] {
            if keyCode == 124 { return .nextPane }
            if keyCode == 123 { return .previousPane }
        }
        if flags == [.command, .shift] {
            if keyCode == 30 { return .nextTerminalTab }
            if keyCode == 33 { return .previousTerminalTab }
        }
        return nil
    }
}

@MainActor
enum TerminalTabRegistry {
    static weak var active: TerminalTabsModel?

    @discardableResult
    static func cycle(backwards: Bool) -> Bool {
        guard let active, active.tabs.count > 1 else { return false }
        active.selectNext(backwards: backwards)
        return true
    }
}

@MainActor
enum SectionWindowMenu {
    private static var installed = false
    private static var hintMonitor: Any?
    private static var keyMonitor: Any?
    private static var keyObserver: Any?
    static let filesMenuTitle = "Open Files Window"

    static func install(attempt: Int = 0) {
        installMonitors()
        installKeyObserver()
        if installMenuItems() { installed = true }
        guard !installed, attempt < 40 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            install(attempt: attempt + 1)
        }
    }

    private static func installKeyObserver() {
        guard keyObserver == nil else { return }
        keyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { _ = installMenuItems() }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { WindowTabs.clearHints() }
        }
    }

    @discardableResult
    private static func installMenuItems() -> Bool {
        guard let mainMenu = NSApp.mainMenu,
            let submenu =
                (mainMenu.items.first { $0.submenu?.title == "Window" }
                ?? mainMenu.items.first { $0.title == "Window" })?.submenu
        else { return false }
        if submenu.items.contains(where: { $0.title == filesMenuTitle }) { return true }
        let target = SectionWindowMenuTarget.shared
        var index = 0
        let next = NSMenuItem(
            title: "Show Next Tab", action: #selector(SectionWindowMenuTarget.nextTab(_:)),
            keyEquivalent: "\t")
        next.keyEquivalentModifierMask = .control
        next.target = target
        submenu.insertItem(next, at: index)
        index += 1
        let previous = NSMenuItem(
            title: "Show Previous Tab",
            action: #selector(SectionWindowMenuTarget.previousTab(_:)), keyEquivalent: "\t")
        previous.keyEquivalentModifierMask = [.control, .shift]
        previous.target = target
        submenu.insertItem(previous, at: index)
        index += 1
        submenu.insertItem(NSMenuItem.separator(), at: index)
        index += 1
        for entry in paneNavigationItems {
            let item = NSMenuItem(
                title: entry.title, action: #selector(SectionWindowMenuTarget.paneCommand(_:)),
                keyEquivalent: entry.key)
            item.keyEquivalentModifierMask = entry.modifiers
            item.target = target
            item.representedObject = entry.tag
            submenu.insertItem(item, at: index)
            index += 1
        }
        submenu.insertItem(NSMenuItem.separator(), at: index)
        index += 1
        let files = NSMenuItem(
            title: "Open Files Window",
            action: #selector(SectionWindowMenuTarget.openFiles(_:)), keyEquivalent: "o")
        files.keyEquivalentModifierMask = [.command, .shift]
        files.target = target
        submenu.insertItem(files, at: index)
        index += 1
        submenu.insertItem(NSMenuItem.separator(), at: index)
        index += 1
        for destination in MainDestination.homeItems + [.extensions, .settings] {
            guard destination != .about else { continue }
            let item = NSMenuItem(
                title: "Open \(destination.title) in New Window",
                action: #selector(SectionWindowMenuTarget.openSection(_:)), keyEquivalent: "")
            item.target = target
            item.representedObject = destination.rawValue
            submenu.insertItem(item, at: index)
            index += 1
        }
        submenu.insertItem(NSMenuItem.separator(), at: index)
        return true
    }

    private static let paneNavigationItems:
        [(title: String, key: String, modifiers: NSEvent.ModifierFlags, tag: String)] = [
            ("Next Pane Tab", "\u{2192}", [.command, .option], "nextPaneTab"),
            ("Previous Pane Tab", "\u{2190}", [.command, .option], "previousPaneTab"),
            ("Focus Next Pane", "\u{2192}", [.command, .control], "nextPane"),
            ("Focus Previous Pane", "\u{2190}", [.command, .control], "previousPane"),
            ("Next Terminal Tab", "]", [.command, .shift], "nextTerminalTab"),
            ("Previous Terminal Tab", "[", [.command, .shift], "previousTerminalTab"),
        ]

    private static func installMonitors() {
        guard hintMonitor == nil, keyMonitor == nil else { return }
        hintMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            let commandDown = event.modifierFlags.contains(.command)
            MainActor.assumeIsolated { WindowTabs.showHints(commandDown) }
            return event
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let characters = event.charactersIgnoringModifiers
            let keyCode = event.keyCode
            let modifiers = event.modifierFlags
            let handled = MainActor.assumeIsolated { () -> Bool in
                let flags = modifiers.chordOnly
                if flags == [.command, .shift], characters?.lowercased() == "o" {
                    SectionWindowMenuTarget.shared.openFilesWindow()
                    return true
                }
                if flags == .command, characters?.lowercased() == "w" {
                    return CloseCommand.perform(on: NSApp.keyWindow)
                }
                if let command = WorkspaceKeyCommand.resolve(
                    characters: characters, keyCode: keyCode, modifiers: modifiers)
                {
                    switch command {
                    case .nextPaneTab:
                        return WorkspaceModel.shared.cycleTab(backwards: false)
                    case .previousPaneTab:
                        return WorkspaceModel.shared.cycleTab(backwards: true)
                    case .nextPane:
                        return WorkspaceModel.shared.cyclePane(backwards: false)
                    case .previousPane:
                        return WorkspaceModel.shared.cyclePane(backwards: true)
                    case .nextTerminalTab:
                        return TerminalTabRegistry.cycle(backwards: false)
                    case .previousTerminalTab:
                        return TerminalTabRegistry.cycle(backwards: true)
                    }
                }
                let window = NSApp.keyWindow
                guard
                    let command = WindowTabKeyCommand.resolve(
                        characters: characters, keyCode: keyCode, modifiers: modifiers,
                        tabbed: WindowTabs.isTabbed(window))
                else {
                    let controlTab =
                        keyCode == 48 && flags.contains(.control)
                        && !flags.contains(.command)
                    guard controlTab else { return false }
                    return WorkspaceModel.shared.cycleTab(backwards: flags.contains(.shift))
                }
                switch command {
                case let .selectTab(index):
                    return WindowTabs.selectTab(index: index, in: window)
                case .nextTab:
                    return WindowTabs.selectNextTab(in: window, backwards: false)
                case .previousTab:
                    return WindowTabs.selectNextTab(in: window, backwards: true)
                }
            }
            return handled ? nil : event
        }
    }
}

@MainActor
enum CloseCommand {
    static func perform(on window: NSWindow?) -> Bool {
        guard let window else { return true }
        if WindowTabs.isTabbed(window) {
            window.close()
            return true
        }
        if !isMainWindow(window) {
            window.performClose(nil)
            return true
        }
        guard workspaceIsOnScreen else { return true }
        WorkspaceModel.shared.closeFocusedTab()
        return true
    }

    private static var workspaceIsOnScreen: Bool {
        let store = SharedDefaults.store
        return store.string(forKey: AppStorageKeys.General.mainWindowSection)
            == MainDestination.machines.rawValue
            && store.string(forKey: AppStorageKeys.Machines.mode) == MachinesMode.workspace.rawValue
    }

    private static func isMainWindow(_ window: NSWindow) -> Bool {
        window.identifier?.rawValue == MainWindowIdentifier.value
    }
}

@MainActor
final class SectionWindowMenuTarget: NSObject {
    static let shared = SectionWindowMenuTarget()

    @objc func openSection(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
            let destination = MainDestination(rawValue: raw)
        else { return }
        SectionWindow.open(destination, mode: .alwaysNew)
    }

    @objc func openFiles(_ sender: NSMenuItem) {
        openFilesWindow()
    }

    func openFilesWindow() {
        let model = MachinesModel.shared
        model.ensureSelection()
        guard let selection = model.selection else { return }
        FinderWindow.open(session: model.session(for: selection))
    }

    @objc func paneCommand(_ sender: NSMenuItem) {
        switch sender.representedObject as? String {
        case "nextPaneTab": WorkspaceModel.shared.cycleTab(backwards: false)
        case "previousPaneTab": WorkspaceModel.shared.cycleTab(backwards: true)
        case "nextPane": WorkspaceModel.shared.cyclePane(backwards: false)
        case "previousPane": WorkspaceModel.shared.cyclePane(backwards: true)
        case "nextTerminalTab": TerminalTabRegistry.cycle(backwards: false)
        case "previousTerminalTab": TerminalTabRegistry.cycle(backwards: true)
        default: break
        }
    }

    @objc func nextTab(_ sender: NSMenuItem) {
        _ = WindowTabs.selectNextTab(in: NSApp.keyWindow, backwards: false)
    }

    @objc func previousTab(_ sender: NSMenuItem) {
        _ = WindowTabs.selectNextTab(in: NSApp.keyWindow, backwards: true)
    }
}
