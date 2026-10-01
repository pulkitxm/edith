import EdithKit
import Foundation

@MainActor
final class NotchBrowserActionBridge {
    static let shared = NotchBrowserActionBridge()
    static let disabledMessage =
        "The notch browser is off. Turn it on in Edith's Extensions, then retry."

    private var token: NSObjectProtocol?

    func install(services: AppServices) {
        guard token == nil else { return }
        token = IPC.observe(
            IPC.Name.requestNotchBrowserAction,
            info: { [weak self] info in
                MainActor.assumeIsolated {
                    self?.receive(info, store: services.notchBrowser)
                }
            })
    }

    static func reply(
        to info: [AnyHashable: Any], store: NotchBrowserStore?, now: Date = Date()
    ) -> [String: Any]? {
        let requestID = info[NotchBrowserIPC.requestIDKey] as? String
        guard let runtime = NotchBrowserRuntimeRequest(payload: info) else {
            guard let requestID else { return nil }
            return [
                NotchBrowserIPC.okKey: false, NotchBrowserIPC.requestIDKey: requestID,
                NotchBrowserIPC.errorKey: "The browser request is invalid.",
            ]
        }
        guard runtime.isLive(at: now) else {
            return NotchBrowserSnapshot(
                attached: false, profile: nil, profiles: [], tabs: [], sync: "idle",
                canReopen: false
            ).resultPayload(
                requestID: runtime.requestID, error: "The browser request expired before it ran.")
        }
        guard let store else {
            return NotchBrowserSnapshot(
                attached: false, profile: nil, profiles: [], tabs: [], sync: "idle",
                canReopen: false
            ).resultPayload(requestID: runtime.requestID, error: disabledMessage)
        }
        do {
            return try store.perform(runtime.request).resultPayload(requestID: runtime.requestID)
        } catch {
            return store.snapshot().resultPayload(
                requestID: runtime.requestID, error: error.localizedDescription)
        }
    }

    private func receive(_ info: [AnyHashable: Any], store: NotchBrowserStore?) {
        guard let payload = Self.reply(to: info, store: store) else { return }
        IPC.post(IPC.Name.notchBrowserActionResult, userInfo: payload)
    }
}
