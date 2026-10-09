import AppKit
import EdithExtensionSupport

public enum StatusItemMenu {
    private static let handler = StatusMenuHandler()

    @MainActor
    public static func attach(to item: NSStatusItem, target: AnyObject, action: Selector) {
        item.button?.target = target
        item.button?.action = action
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    @MainActor
    public static func handleClick(on item: NSStatusItem, primary: () -> Void) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            show(from: item)
        } else {
            primary()
        }
    }

    @MainActor
    public static func show(from item: NSStatusItem) {
        let menu = NSMenu()
        let open = NSMenuItem(
            title: "Open Settings", action: #selector(StatusMenuHandler.open), keyEquivalent: "")
        open.target = handler
        menu.addItem(open)
        guard let button = item.button else { return }
        menu.popUp(
            positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }
}

private final class StatusMenuHandler: NSObject {
    @objc func open() {
        MainActor.assumeIsolated { ExtensionPresentation.showWindow() }
    }

}
