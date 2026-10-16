import AppKit

@MainActor
final class MachineWindowCommands: NSObject {
    static let shared = MachineWindowCommands()
    static let menuTitle = "Open Files Window"
    private var monitor: Any?
    private var generation = UUID()
    private var workspaceVisible = 0

    func workspaceAppeared() { workspaceVisible += 1 }
    func workspaceDisappeared() { workspaceVisible = max(0, workspaceVisible - 1) }

    func install() {
        guard monitor == nil else { return }
        generation = UUID()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated {
                self?.handle(
                    characters: event.charactersIgnoringModifiers, keyCode: event.keyCode,
                    modifiers: event.modifierFlags) ?? false
            }
            return handled ? nil : event
        }
        installMenu(token: generation, attempt: 0)
    }

    func shutdown() {
        generation = UUID()
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        workspaceVisible = 0
        if let menu = Self.windowMenu {
            for item in menu.items where item.target === self { menu.removeItem(item) }
        }
    }

    func handle(characters: String?, keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        let flags = modifiers.intersection([.command, .option, .control, .shift])
        if flags == [.command, .shift], characters?.lowercased() == "o" {
            openFilesWindow()
            return true
        }
        guard workspaceVisible > 0 else { return false }
        let model = WorkspaceModel.shared
        if flags == [.command, .option] {
            if keyCode == 124 { return model.cycleTab(backwards: false) }
            if keyCode == 123 { return model.cycleTab(backwards: true) }
        }
        if flags == [.command, .control] {
            if keyCode == 124 { return model.cyclePane(backwards: false) }
            if keyCode == 123 { return model.cyclePane(backwards: true) }
        }
        return false
    }

    @objc func openFilesWindow() {
        let model = MachinesModel.shared
        model.ensureSelection()
        guard let selection = model.selection else { return }
        FinderWindow.open(session: model.session(for: selection))
    }

    private static var windowMenu: NSMenu? {
        NSApp.mainMenu?.items.first {
            $0.title == "Window" || $0.submenu?.title == "Window"
        }?.submenu
    }

    private func installMenu(token: UUID, attempt: Int) {
        guard token == generation else { return }
        if let menu = Self.windowMenu {
            guard !menu.items.contains(where: { $0.title == Self.menuTitle }) else { return }
            let item = NSMenuItem(
                title: Self.menuTitle, action: #selector(openFilesWindow), keyEquivalent: "o")
            item.keyEquivalentModifierMask = [.command, .shift]
            item.target = self
            let index = menu.items.firstIndex { $0.title.hasPrefix("Open ") } ?? menu.items.count
            menu.insertItem(item, at: index)
        } else if attempt < 40 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.installMenu(token: token, attempt: attempt + 1)
            }
        }
    }
}
