import AppKit
import EdithKit

final class HelperAppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        SharedDefaults.migrate()
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "eyeglasses", accessibilityDescription: nil)
        item.button?.toolTip = "Edith helper (placeholder — real modules land in a later PR)"
        statusItem = item
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = HelperAppDelegate()
app.delegate = delegate
app.run()
