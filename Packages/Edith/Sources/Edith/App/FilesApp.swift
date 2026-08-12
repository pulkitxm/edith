import EdithKit
import SwiftUI

@MainActor
final class FilesAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        applyAppearance(
            SharedDefaults.store.string(forKey: AppStorageKeys.General.appearance) ?? "system")
        NSApp.setActivationPolicy(.regular)
        FinderOpenBridge.start()
        guard
            let request = FilesLaunch.parse(
                Array(ProcessInfo.processInfo.arguments.dropFirst()))
        else { return }
        FinderOpenBridge.open(machineID: request.machine, path: request.path)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

public struct EdithFilesApp: App {
    @NSApplicationDelegateAdaptor(FilesAppDelegate.self) private var delegate

    public init() {}

    public var body: some Scene {
        Settings {
            Color.clear.frame(width: UIScale.pt(1), height: UIScale.pt(1))
        }
    }
}
