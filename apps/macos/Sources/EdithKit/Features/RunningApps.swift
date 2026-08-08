import AppKit
import Foundation

public enum RunningApps {
    public static let protectedBundleIDs: Set<String> = [
        "com.apple.finder", "com.pulkit.edith", "com.pulkit.edith.statusbar",
    ]

    public static func quit(pid: pid_t, force: Bool) {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return }
        guard !protectedBundleIDs.contains(app.bundleIdentifier ?? "") else { return }
        if force { app.forceTerminate() } else { app.terminate() }
    }

    public static func quitEverythingElse(force: Bool) {
        let mine = ProcessInfo.processInfo.processIdentifier
        for app in NSWorkspace.shared.runningApplications
        where app.activationPolicy == .regular
            && app.processIdentifier != mine
            && !protectedBundleIDs.contains(app.bundleIdentifier ?? "")
        {
            if force { app.forceTerminate() } else { app.terminate() }
        }
    }
}
