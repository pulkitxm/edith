import EdithKit
import Foundation

enum CompanionStopBridge {
    private static var token: NSObjectProtocol?

    static func install() {
        guard token == nil else { return }
        token = IPC.observe(IPC.Name.requestCompanionStop) { info in
            MainActor.assumeIsolated {
                let requestID = info["requestID"] as? String ?? ""
                let stopped = CompanionGeneration.stopAll()
                IPC.post(
                    IPC.Name.companionStopResult,
                    userInfo: [
                        "ok": true,
                        "requestID": requestID,
                        "stopped": String(stopped),
                    ])
            }
        }
    }
}
