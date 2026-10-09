import AppKit
import Observation
import Sparkle

@MainActor
@Observable
final class HostUpdater {
    private var controller: SPUStandardUpdaterController?

    init() {
        guard Bundle.main.bundleIdentifier == "com.pulkit.edith",
            Bundle.main.bundleURL.path == "/Applications/Edith.app"
        else { return }
        controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    }

    var available: Bool { controller != nil }

    func checkForUpdates() { controller?.checkForUpdates(nil) }
}
