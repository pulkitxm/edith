import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import EdithHostCore
import SwiftUI

enum HostSectionOpenMode {
    case reuseMostRecent
    case alwaysNew
}

enum HostWindowTabCommand: Equatable {
    case select(Int)
    case next
    case previous

    static func resolve(
        characters: String?, keyCode: UInt16, modifiers: NSEvent.ModifierFlags, tabbed: Bool
    ) -> Self? {
        guard tabbed else { return nil }
        let flags = modifiers.intersection([.command, .option, .control, .shift])
        if keyCode == 48, flags.contains(.control), !flags.contains(.command) {
            return flags.contains(.shift) ? .previous : .next
        }
        guard flags == .command, let characters, let value = Int(characters),
            (1...9).contains(value)
        else { return nil }
        return .select(value - 1)
    }
}

@MainActor
final class HostSectionWindows: NSObject, NSWindowDelegate, NSMenuItemValidation {
    static let baseContentSize = NSSize(width: 880, height: 640)
    static let baseMinimumSize = NSSize(width: 560, height: 420)
    private struct Entry {
        let window: NSWindow
        let page: HostNavigationPage
        let didClose: (() -> Void)?
    }
    private var entries: [Entry] = []
    private let content: (HostNavigationPage) -> AnyView
    private let makeWindow: (NSRect) -> NSWindow
    private let present: (NSWindow) -> Void
    private let visibleFrame: () -> NSRect
    private let saveFrames: Bool
    private var keyMonitor: Any?
    private var hintMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    private var baseTitles: [ObjectIdentifier: String] = [:]
    private var installation = UUID()

    init(
        saveFrames: Bool = true,
        makeWindow: @escaping (NSRect) -> NSWindow = {
            NSWindow(
                contentRect: $0, styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered, defer: false)
        },
        present: @escaping (NSWindow) -> Void = {
            if $0.isMiniaturized { $0.deminiaturize(nil) }
            $0.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        },
        visibleFrame: @escaping () -> NSRect = {
            NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        },
        content: @escaping (HostNavigationPage) -> AnyView
    ) {
        self.saveFrames = saveFrames
        self.makeWindow = makeWindow
        self.present = present
        self.visibleFrame = visibleFrame
        self.content = content
    }

    var openDestinations: [String] { entries.map { $0.page.id } }
    func contains(_ window: NSWindow?) -> Bool {
        guard let window else { return false }
        return entries.contains { $0.window === window }
    }
    @discardableResult
    func focusExisting(_ id: String) -> Bool {
        guard let entry = entries.first(where: { $0.page.id == id }) else { return false }
        present(entry.window)
        return true
    }
    @discardableResult
    func open(_ id: String, mode: HostSectionOpenMode = .reuseMostRecent) -> NSWindow? {
        guard let page = HostNavigationCatalog.pages.first(where: { $0.id == id }), id != "about"
        else { return nil }
        if let existing = entries.first(where: { $0.page.id == id }) {
            present(existing.window)
            return existing.window
        }
        let hosting = NSHostingController(rootView: content(page))
        hosting.sizingOptions = []
        return create(page: page, controller: hosting, mode: mode, didClose: nil)
    }

    func openOwned(
        id: UUID, kind: HostMachinesWindowTarget.Kind, controller: NSViewController,
        didClose: @escaping () -> Void
    ) -> NSWindow {
        let title: String
        let symbol: String
        switch kind {
        case .machine: title = "Machine"; symbol = "server.rack"
        case .files: title = "Files"; symbol = "folder"
        case .docker: title = "Docker"; symbol = "shippingbox"
        case .terminal: title = "Terminal"; symbol = "terminal"
        }
        let page = HostNavigationPage(
            id: "machines.window." + id.uuidString, title: title, symbol: symbol,
            extensionID: "machines")
        return create(page: page, controller: controller, mode: .alwaysNew, didClose: didClose)
    }

    func closeOwned(id: UUID) {
        entries.first(where: { $0.page.id == "machines.window." + id.uuidString })?.window.close()
    }

    func openHerdrOwned(
        id: UUID, target: HostHerdrWindowTarget, controller: NSViewController,
        didClose: @escaping () -> Void
    ) -> NSWindow {
        let page = HostNavigationPage(
            id: "herdr.window." + id.uuidString,
            title: target.title, symbol: "terminal", extensionID: "herdr")
        return create(
            page: page, controller: controller, mode: .alwaysNew, didClose: didClose,
            contentSize: NSSize(width: target.width, height: target.height),
            minimumSize: NSSize(width: target.minimumWidth, height: target.minimumHeight))
    }

    func closeHerdrOwned(id: UUID) {
        entries.first(where: { $0.page.id == "herdr.window." + id.uuidString })?.window.close()
    }

    private func create(
        page: HostNavigationPage, controller: NSViewController, mode: HostSectionOpenMode,
        didClose: (() -> Void)?, contentSize: NSSize = HostSectionWindows.baseContentSize,
        minimumSize: NSSize = HostSectionWindows.baseMinimumSize
    ) -> NSWindow {
        let visible = visibleFrame()
        let size = HostWindowFramePolicy.fitted(contentSize, visible: visible.size)
        let window = makeWindow(NSRect(origin: .zero, size: size))
        window.title = page.title
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.contentMinSize = HostWindowFramePolicy.fitted(
            minimumSize, visible: visible.size)
        window.tabbingMode = .automatic
        window.tabbingIdentifier = "EdithSection"
        window.identifier = NSUserInterfaceItemIdentifier("EdithSection." + page.id)
        window.contentViewController = controller
        window.setContentSize(size)
        window.delegate = self
        let host = mode == .reuseMostRecent ? entries.first?.window : nil
        entries.insert(Entry(window: window, page: page, didClose: didClose), at: 0)
        if let host, host.isVisible {
            host.addTabbedWindow(window, ordered: .above)
        } else if saveFrames {
            window.setFrameAutosaveName("EdithSectionWindow")
            if window.frame.origin == .zero { window.center() }
            offset(window, inside: visible)
        }
        present(window)
        return window
    }
    private func offset(_ window: NSWindow, inside visible: NSRect) {
        let occupied = NSApp.windows.filter { $0 !== window && $0.isVisible }.map(\.frame)
        var frame = window.frame
        if frame.width > visible.width * 0.9 {
            frame.size = HostWindowFramePolicy.fitted(Self.baseContentSize, visible: visible.size)
        }
        var attempts = 0
        while occupied.contains(where: { abs($0.minX - frame.minX) < 12 }), attempts < 8 {
            frame.origin.x += 26; frame.origin.y -= 26; attempts += 1
        }
        if !visible.contains(frame.origin) {
            frame.origin = NSPoint(
                x: visible.midX - frame.width / 2, y: visible.midY - frame.height / 2)
        }
        window.setFrame(frame, display: false)
    }
    func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
            let index = entries.firstIndex(where: { $0.window === window }), index > 0
        else { return }
        entries.insert(entries.remove(at: index), at: 0)
    }
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        clearHints()
        let closed = entries.filter { $0.window === window }
        entries.removeAll { $0.window === window }
        for entry in closed { entry.didClose?() }
    }
    func closeAll() {
        clearHints()
        let closed = entries
        entries.removeAll()
        for entry in closed { entry.window.close(); entry.didClose?() }
    }
    static func tabbedWindows(_ window: NSWindow?) -> [NSWindow] {
        guard let group = window?.tabGroup, group.windows.count > 1 else { return [] }
        return group.windows
    }
    @discardableResult
    func perform(_ command: HostWindowTabCommand, in window: NSWindow?) -> Bool {
        let windows = Self.tabbedWindows(window)
        guard let window, let current = windows.firstIndex(of: window) else { return false }
        let index: Int
        switch command {
        case .select(let selected): index = selected
        case .next: index = (current + 1) % windows.count
        case .previous: index = (current - 1 + windows.count) % windows.count
        }
        guard windows.indices.contains(index) else { return false }
        present(windows[index])
        return true
    }
    func showHints(_ show: Bool, in window: NSWindow?) {
        guard show else { clearHints(); return }
        for (index, window) in Self.tabbedWindows(window).enumerated() where index < 9 {
            let key = ObjectIdentifier(window)
            if baseTitles[key] == nil { baseTitles[key] = window.title }
            if let title = baseTitles[key] { window.title = "⌘\(index + 1)  \(title)" }
        }
    }
    func clearHints() {
        for window in NSApp.windows {
            if let title = baseTitles[ObjectIdentifier(window)] { window.title = title }
        }
        baseTitles.removeAll()
    }
    func install() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated {
                guard let self,
                    let command = HostWindowTabCommand.resolve(
                        characters: event.charactersIgnoringModifiers, keyCode: event.keyCode,
                        modifiers: event.modifierFlags,
                        tabbed: !Self.tabbedWindows(NSApp.keyWindow).isEmpty)
                else { return false }
                return self.perform(command, in: NSApp.keyWindow)
            }
            return handled ? nil : event
        }
        hintMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) {
            [weak self] event in
            MainActor.assumeIsolated {
                self?.showHints(event.modifierFlags.contains(.command), in: NSApp.keyWindow)
            }
            return event
        }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.clearHints() } }
        installMenu(token: installation, attempt: 0)
    }
    private func installMenu(token: UUID, attempt: Int) {
        guard token == installation else { return }
        if let menu = NSApp.mainMenu?.items.first(where: {
            $0.title == "Window" || $0.submenu?.title == "Window"
        })?.submenu {
            populate(menu)
        } else if attempt < 40 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.installMenu(token: token, attempt: attempt + 1)
            }
        }
    }
    func populate(_ menu: NSMenu) {
        guard !menu.items.contains(where: { $0.identifier?.rawValue == "EdithSectionMenu" }) else {
            return
        }
        var items: [NSMenuItem] = []
        let next = NSMenuItem(
            title: "Show Next Tab", action: #selector(nextTab), keyEquivalent: "\t")
        next.keyEquivalentModifierMask = .control
        items.append(next)
        let previous = NSMenuItem(
            title: "Show Previous Tab", action: #selector(previousTab), keyEquivalent: "\t")
        previous.keyEquivalentModifierMask = [.control, .shift]
        items.append(previous)
        items.append(.separator())
        for page in HostNavigationCatalog.pages where page.id != "about" {
            let item = NSMenuItem(
                title: "Open " + page.title + " in New Window", action: #selector(openSection),
                keyEquivalent: "")
            item.representedObject = page.id
            items.append(item)
        }
        items.append(.separator())
        for (index, item) in items.enumerated() {
            item.target = self
            item.identifier = NSUserInterfaceItemIdentifier("EdithSectionMenu")
            menu.insertItem(item, at: index)
        }
    }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(nextTab) || menuItem.action == #selector(previousTab) {
            return !Self.tabbedWindows(NSApp.keyWindow).isEmpty
        }
        return (menuItem.representedObject as? String).map { id in
            HostNavigationCatalog.pages.contains { $0.id == id } && id != "about"
        } ?? false
    }
    @objc private func nextTab(_ sender: NSMenuItem) { _ = perform(.next, in: NSApp.keyWindow) }
    @objc private func previousTab(_ sender: NSMenuItem) {
        _ = perform(.previous, in: NSApp.keyWindow)
    }
    @objc private func openSection(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        _ = open(id, mode: .alwaysNew)
    }
    func uninstall() {
        installation = UUID()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let hintMonitor { NSEvent.removeMonitor(hintMonitor) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        keyMonitor = nil; hintMonitor = nil; resignObserver = nil
        clearHints()
        if let menu = NSApp.mainMenu?.items.first(where: {
            $0.title == "Window" || $0.submenu?.title == "Window"
        })?.submenu {
            for item in menu.items where item.target === self { menu.removeItem(item) }
        }
    }
}
