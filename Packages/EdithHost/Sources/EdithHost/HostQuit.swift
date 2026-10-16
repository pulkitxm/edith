import AppKit

@MainActor enum HostQuit {
    static func terminate() {
        for window in NSApp.windows {
            while let sheet = window.attachedSheet { window.endSheet(sheet) }
        }
        NSApp.terminate(nil)
    }

    static func closeWindows() {
        conceal()
        NSApp.setActivationPolicy(.accessory)
    }

    static func conceal() {
        for window in NSApp.windows {
            while let sheet = window.attachedSheet { window.endSheet(sheet) }
            window.orderOut(nil)
        }
    }
}

@MainActor enum HostInstallLocationAlert {
    static func refuse() {
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        application.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Open Edith from Applications"
        alert.informativeText =
            "This copy of Edith is at \(Bundle.main.bundlePath). Only the copy in your "
            + "Applications folder runs Edith's background agent and menu bar. Move Edith to "
            + "Applications and open it from there."
        alert.addButton(withTitle: "Quit")
        alert.runModal()
    }
}
