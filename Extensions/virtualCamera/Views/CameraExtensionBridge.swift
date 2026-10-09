import EdithExtensionUI
import EdithExtensionSupport
import Foundation

@MainActor
enum CameraExtensionBridge {
    private static var observer: NSObjectProtocol?
    private static let manager = VirtualCameraExtensionManager()

    static func install() {
        guard observer == nil else { return }
        observer = IPC.observe(IPC.Name.requestCameraExtensionAction) { info in
            MainActor.assumeIsolated { receive(info) }
        }
    }

    static func reply(to info: [AnyHashable: Any], now: Date = Date()) -> [String: Any]? {
        let requestID = info[CameraExtensionIPC.requestIDKey] as? String
        guard let runtime = CameraExtensionRuntimeRequest(payload: info) else {
            guard let requestID else { return nil }
            return [
                CameraExtensionIPC.okKey: false, CameraExtensionIPC.requestIDKey: requestID,
                CameraExtensionIPC.errorKey: "The camera extension request is invalid.",
            ]
        }
        guard runtime.isLive(at: now) else {
            return snapshot(manager.phase, changed: false).resultPayload(
                requestID: runtime.requestID,
                error: "The camera extension request expired before it ran.")
        }
        let changed = perform(runtime.request)
        return snapshot(manager.phase, changed: changed).resultPayload(requestID: runtime.requestID)
    }

    private static func receive(_ info: [AnyHashable: Any]) {
        guard let payload = reply(to: info) else { return }
        IPC.post(IPC.Name.cameraExtensionActionResult, userInfo: payload)
    }

    private static func perform(_ request: CameraExtensionRequest) -> Bool {
        manager.refresh()
        switch request {
        case .status:
            return false
        case .install:
            manager.install()
            return manager.phase == .installing
        case .remove:
            manager.uninstall()
            return manager.phase == .removing
        }
    }

    private static func snapshot(
        _ phase: VirtualCameraExtensionPhase, changed: Bool
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
        case .failed: "failed"
        }
    }
}
