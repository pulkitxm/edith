import EdithKit
import Foundation

enum StudioJobBridge {
    private static var token: NSObjectProtocol?

    static func install() {
        guard token == nil else { return }
        token = IPC.observe(IPC.Name.requestStudioCancel) { info in
            MainActor.assumeIsolated {
                let requestID = info["requestID"] as? String ?? ""
                let tools = StudioRunRegistry.cancelRunning()
                IPC.post(
                    IPC.Name.studioJobResult,
                    userInfo: [
                        "ok": true,
                        "requestID": requestID,
                        "cancelled": String(tools.count),
                        "tools": tools.joined(separator: "\n"),
                    ])
            }
        }
    }
}
