import AppKit
import EdithExtensionSupport
import Foundation

extension NotchShelfController {
    func openCustomization(tileID: String? = nil) {
        let channel = ExtensionSharedState(
            root: context.sharedState.root, namespace: context.sharedState.namespace,
            owner: "notchShelf")
        var values = channel.values(for: "notchShelf")
        values["surface.openEditor"] = "notch"
        values["surface.openEditorToken"] = UUID().uuidString
        values["surface.openEditorTileID"] = tileID.flatMap {
            !$0.isEmpty && $0.utf8.count <= 256 && !$0.contains("\0") ? $0 : nil
        }
        try? channel.publish(values)
        if !NotchWorkerPresentation.isTesting {
            NSWorkspace.shared.open(Bundle.main.bundleURL)
        }
    }

    func startSurfaceObservation() {
        installContextObserver()
        beginGlanceRefresh()
    }
}
