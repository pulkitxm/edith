import AppKit
import EdithExtensionSupport
import Foundation

extension NotchShelfController {
    func openCustomization() {
        let channel = ExtensionSharedState(
            root: context.sharedState.root, namespace: context.sharedState.namespace,
            owner: "notchShelf")
        var values = channel.values(for: "notchShelf")
        values["surface.openEditor"] = "notch"
        values["surface.openEditorToken"] = UUID().uuidString
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
