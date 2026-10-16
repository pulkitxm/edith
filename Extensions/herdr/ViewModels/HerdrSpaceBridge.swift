import EdithExtensionSupport
import EdithExtensionUI
import Foundation

enum HerdrSpaceBridge {
    private static var token: NSObjectProtocol?

    static func shutdown() {
        HerdrIPC.stopObserving(token)
        token = nil
    }

    static func install() {
        guard token == nil else { return }
        token = HerdrIPC.observe(HerdrIPC.Name.requestHerdrSpaceAction) { info in
            MainActor.assumeIsolated { receive(info) }
        }
    }

    @MainActor
    private static func receive(_ info: [AnyHashable: Any]) {
        let requestID = info["requestID"] as? String ?? ""
        let action = info["action"] as? String ?? "list"
        let window = info["window"] as? String
        switch action {
        case "list":
            reply(requestID, windows: HerdrSpaceWindow.listed(), message: nil, error: nil)
        case "terminal":
            guard let opened = HerdrSpaceWindow.openTerminal(window) else {
                reply(
                    requestID, windows: HerdrSpaceWindow.listed(), message: nil,
                    error: HerdrSpaceWindow.missing(window))
                return
            }
            reply(requestID, windows: [opened], message: "opened a terminal", error: nil)
        case "split":
            let side = info["side"] as? String ?? "right"
            guard let insert = InsertSide(rawValue: side) else {
                reply(
                    requestID, windows: [], message: nil,
                    error: "side must be left, right, top, or bottom")
                return
            }
            guard let opened = HerdrSpaceWindow.split(window, side: insert) else {
                reply(
                    requestID, windows: HerdrSpaceWindow.listed(), message: nil,
                    error: HerdrSpaceWindow.missing(window))
                return
            }
            reply(requestID, windows: [opened], message: "split \(side)", error: nil)
        default:
            reply(requestID, windows: [], message: nil, error: "unknown space action")
        }
    }

    @MainActor
    private static func reply(
        _ requestID: String, windows: [HerdrSpaceWindow.Info], message: String?, error: String?
    ) {
        let payload = windows.map {
            ["id": $0.id, "title": $0.title, "tabs": $0.tabs, "panes": $0.panes] as [String: Any]
        }
        let data = try? JSONSerialization.data(withJSONObject: payload)
        let text = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        var userInfo: [String: Any] = [
            "ok": error == nil, "requestID": requestID, "windows": text,
        ]
        if let message { userInfo["message"] = message }
        if let error { userInfo["error"] = error }
        HerdrIPC.post(HerdrIPC.Name.herdrSpaceActionResult, userInfo: userInfo)
    }
}
