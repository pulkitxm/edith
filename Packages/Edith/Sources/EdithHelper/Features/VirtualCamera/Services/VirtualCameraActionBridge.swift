import EdithKit
import Foundation

@MainActor
final class VirtualCameraActionBridge {
    static let shared = VirtualCameraActionBridge()
    static let disabledMessage =
        "Virtual Camera is off. Turn it on with ed camera on or in Edith's Extensions."

    private var token: NSObjectProtocol?

    func install(services: AppServices) {
        guard token == nil else { return }
        token = IPC.observe(
            IPC.Name.requestVirtualCameraAction,
            info: { [weak self] info in
                MainActor.assumeIsolated {
                    self?.receive(info, engine: services.virtualCamera)
                }
            })
    }

    static func reply(
        to info: [AnyHashable: Any], engine: VirtualCameraEngine?, now: Date = Date()
    ) -> [String: Any]? {
        let requestID = info[VirtualCameraIPC.requestIDKey] as? String
        guard let runtime = VirtualCameraRuntimeRequest(payload: info) else {
            guard let requestID else { return nil }
            return [
                VirtualCameraIPC.okKey: false, VirtualCameraIPC.requestIDKey: requestID,
                VirtualCameraIPC.errorKey: "The camera request is invalid.",
            ]
        }
        let stored = VirtualCameraSnapshot.stored(helperRunning: true)
        guard runtime.isLive(at: now) else {
            return stored.resultPayload(
                requestID: runtime.requestID, error: "The camera request expired before it ran.")
        }
        guard let engine else {
            if runtime.request == .status {
                return stored.resultPayload(requestID: runtime.requestID)
            }
            return stored.resultPayload(requestID: runtime.requestID, error: disabledMessage)
        }
        do {
            let snapshot = try engine.perform(runtime.request)
            return snapshot.resultPayload(requestID: runtime.requestID)
        } catch {
            return engine.snapshot().resultPayload(
                requestID: runtime.requestID, error: error.localizedDescription)
        }
    }

    private func receive(_ info: [AnyHashable: Any], engine: VirtualCameraEngine?) {
        guard let payload = Self.reply(to: info, engine: engine) else { return }
        IPC.post(IPC.Name.virtualCameraActionResult, userInfo: payload)
    }
}
