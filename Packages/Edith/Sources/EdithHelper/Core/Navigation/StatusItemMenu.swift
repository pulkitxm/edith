import AppKit
import EdithKit

enum StatusItemMenu {
    private static let handler = StatusMenuHandler()

    @MainActor
    static func attach(to item: NSStatusItem, target: AnyObject, action: Selector) {
        item.button?.target = target
        item.button?.action = action
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    @MainActor
    static func handleClick(on item: NSStatusItem, primary: () -> Void) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            show(from: item)
        } else {
            primary()
        }
    }

    @MainActor
    static func show(from item: NSStatusItem) {
        let menu = NSMenu()
        let open = NSMenuItem(
            title: "Open Edith", action: #selector(StatusMenuHandler.open), keyEquivalent: "")
        open.target = handler
        menu.addItem(open)
        menu.addItem(.separator())
        let quit = NSMenuItem(
            title: "Quit Edith", action: #selector(StatusMenuHandler.quit), keyEquivalent: "q")
        quit.target = handler
        menu.addItem(quit)
        guard let button = item.button else { return }
        menu.popUp(
            positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }
}

private final class StatusMenuHandler: NSObject {
    @objc func open() {
        MainActor.assumeIsolated { MainApp.openDashboard() }
    }

    @objc func quit() {
        MainActor.assumeIsolated {
            IPC.post(IPC.Name.quitMainApp)
            NSApp.terminate(nil)
        }
    }
}
