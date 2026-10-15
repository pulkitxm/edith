import AppKit

@MainActor enum HostQuit {
    static func terminate() {
        for window in NSApp.windows {
            while let sheet = window.attachedSheet { window.endSheet(sheet) }
        }
        NSApp.terminate(nil)
    }
}
