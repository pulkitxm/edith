import AppKit
import Foundation

@main @MainActor
struct EdithExtensionCarrier {
    enum Failure: Error { case invalidArguments }

    static func main() throws {
        guard Array(CommandLine.arguments.dropFirst()) == ["--extension-ui-carrier"] else {
            throw Failure.invalidArguments
        }
        let application = NSApplication.shared
        let delegate = CarrierDelegate()
        application.setActivationPolicy(.prohibited)
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}

@MainActor
private final class CarrierDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            NSApplication.shared.terminate(nil)
        }
    }
}
