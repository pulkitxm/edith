import AppKit

enum HostWindowCloseTarget: Equatable {
    case sheet
    case popover
    case terminalTab
    case window
    case nothing
}

enum HostWindowKeyRoute: Equatable {
    case main
    case section
}

@MainActor enum HostWindowClose {
    static let mainIdentifier = "EdithMainWindow"

    static func isMain(_ window: NSWindow?) -> Bool {
        window?.identifier?.rawValue == mainIdentifier
    }

    static func isPopover(_ window: NSWindow) -> Bool {
        String(describing: type(of: window)).localizedCaseInsensitiveContains("popover")
    }

    static func owner(of window: NSWindow?) -> NSWindow? {
        var current = window
        while let window = current {
            if let parent = window.sheetParent {
                current = parent
            } else if isPopover(window), let parent = window.parent {
                current = parent
            } else {
                return window
            }
        }
        return nil
    }

    static func route(
        keyWindow: NSWindow?, isSection: (NSWindow) -> Bool
    ) -> HostWindowKeyRoute? {
        guard let owner = owner(of: keyWindow) else { return nil }
        if isMain(owner) { return .main }
        return isSection(owner) ? .section : nil
    }

    static func target(
        isMain: Bool, sheet: Bool, popover: Bool, closable: Bool, terminalTab: () -> Bool
    ) -> HostWindowCloseTarget {
        if popover { return .popover }
        if sheet { return .sheet }
        if terminalTab() { return .terminalTab }
        if isMain { return .nothing }
        return closable ? .window : .nothing
    }

    static func innermostSheet(of window: NSWindow) -> NSWindow? {
        var sheet = window.sheetParent != nil ? window : window.attachedSheet
        while let next = sheet?.attachedSheet { sheet = next }
        return sheet
    }

    static func popover(of window: NSWindow) -> NSWindow? {
        if isPopover(window) { return window }
        return (window.childWindows ?? []).last { isPopover($0) && $0.isVisible }
    }

    @discardableResult
    static func perform(
        window: NSWindow?, terminalTab: () -> Bool = { false },
        dismiss: @MainActor (NSWindow) -> Void = { HostWindowClose.escape($0) }
    ) -> Bool {
        guard let keyWindow = window, let owner = owner(of: keyWindow) else { return false }
        let sheet = innermostSheet(of: owner)
        let popover = popover(of: isPopover(keyWindow) ? keyWindow : sheet ?? owner)
        let resolved = target(
            isMain: isMain(owner), sheet: sheet != nil, popover: popover != nil,
            closable: owner.styleMask.contains(.closable), terminalTab: terminalTab)
        switch resolved {
        case .sheet:
            if let sheet { dismiss(sheet) }
        case .popover:
            if let popover { dismiss(popover) }
        case .window:
            owner.performClose(nil)
        case .terminalTab, .nothing:
            break
        }
        return resolved != .nothing || isMain(owner)
    }

    static func escape(_ window: NSWindow) {
        guard
            let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
                charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)
        else { return }
        if !window.isKeyWindow, window.canBecomeKey { window.makeKey() }
        NSApp.postEvent(event, atStart: true)
    }
}

@MainActor final class HostMainWindowHider: NSObject {
    static let shared = HostMainWindowHider()

    static func owns(_ window: NSWindow) -> Bool {
        HostWindowClose.isMain(window)
    }

    static func install(on window: NSWindow) {
        guard let button = window.standardWindowButton(.closeButton) else { return }
        button.target = shared
        button.action = #selector(closeButtonPressed(_:))
    }

    static func hide(_ window: NSWindow) {
        while let sheet = window.attachedSheet { window.endSheet(sheet) }
        if window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
            return
        }
        window.orderOut(nil)
        HostApplicationDelegate.dropToAccessoryIfWindowless()
    }

    @objc func closeButtonPressed(_ sender: Any?) {
        guard let window = (sender as? NSButton)?.window ?? NSApp.keyWindow else { return }
        Self.hide(window)
    }
}
