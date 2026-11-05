import EdithExtensionSupport
import Foundation

@MainActor
enum CameraExtensionBridge {
    static func perform(
        _ request: CameraExtensionRequest, on manager: VirtualCameraExtensionManager
    ) -> CameraExtensionSnapshot {
        manager.refresh()
        let changed: Bool
        switch request {
        case .status:
            changed = false
        case .install:
            manager.install()
            changed = manager.phase == .installing
        case .remove:
            manager.uninstall()
            changed = manager.phase == .removing
        }
        return snapshot(manager.phase, changed: changed)
    }

    static func snapshot(
        _ phase: VirtualCameraExtensionPhase, changed: Bool = false
    ) -> CameraExtensionSnapshot {
        CameraExtensionSnapshot(
            phase: token(phase), title: phase.title, detail: phase.detail, changed: changed)
    }

    private static func token(_ phase: VirtualCameraExtensionPhase) -> String {
        switch phase {
        case .checking: "checking"
        case .missingFromBundle: "missingFromBundle"
        case .needsSigning: "needsSigning"
        case .needsApplicationsFolder: "needsApplicationsFolder"
        case .notInstalled: "notInstalled"
        case .installing: "installing"
        case .awaitingApproval: "awaitingApproval"
        case .installed: "installed"
        case .removing: "removing"
        case .restartRequired: "restartRequired"
        case .failed: "failed"
        }
    }
}
