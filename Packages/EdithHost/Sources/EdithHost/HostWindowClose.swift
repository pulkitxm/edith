import AppKit

enum HostWindowCloseTarget: Equatable {
    case sheet
    case popover
    case terminalTab
    case window
    case nothing
}

@MainActor enum HostWindowClose {
    static let mainIdentifier = "EdithMainWindow"

    static func isMain(_ window: NSWindow?) -> Bool {
        window?.identifier?.rawValue == mainIdentifier
    }

    static func target(
        isMain: Bool, sheet: Bool, popover: Bool, closable: Bool, terminalTab: () -> Bool
    ) -> HostWindowCloseTarget {
        if sheet { return .sheet }
        if popover { return .popover }
        if terminalTab() { return .terminalTab }
        if isMain { return .nothing }
        return closable ? .window : .nothing
    }

    static func attachedSheet(of window: NSWindow) -> NSWindow? {
        window.sheetParent != nil ? window : window.attachedSheet
    }

    static func popover(of window: NSWindow) -> NSWindow? {
        (window.childWindows ?? []).first {
            String(describing: type(of: $0)).localizedCaseInsensitiveContains("popover")
        }
    }

    @discardableResult
    static func perform(
        window: NSWindow?, terminalTab: () -> Bool = { false }, dismiss: @MainActor (NSWindow) -> Void = { HostWindowClose.escape($0) }
    ) -> Bool {
        guard let window else { return false }
        let sheet = attachedSheet(of: window)
        let popover = popover(of: sheet ?? window)
        let resolved = target(
            isMain: isMain(window), sheet: sheet != nil, popover: sheet == nil && popover != nil,
            closable: window.styleMask.contains(.closable), terminalTab: terminalTab)
        switch resolved {
        case .sheet:
            if let sheet { dismiss(sheet) }
        case .popover:
            if let popover { dismiss(popover) }
        case .terminalTab:
            break
        case .window:
            window.performClose(nil)
        case .nothing:
            break
        }
        return resolved != .nothing || isMain(window)
    }

    static func escape(_ window: NSWindow) {
        guard
            let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
                charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)
        else { return }
        window.sendEvent(event)
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
