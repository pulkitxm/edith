import EdithKit
import Foundation

enum HomebrewCancelBridge {
    private static var token: NSObjectProtocol?

    static func install() {
        guard token == nil else { return }
        token = IPC.observe(IPC.Name.requestHomebrewCancel) { info in
            MainActor.assumeIsolated {
                let requestID = info["requestID"] as? String ?? ""
                let cancelled = HomebrewCancellation.cancel()
                IPC.post(
                    IPC.Name.homebrewCancelResult,
                    userInfo: [
                        "ok": true,
                        "requestID": requestID,
                        "cancelled": cancelled ? "true" : "false",
                    ])
            }
        }
    }
}
