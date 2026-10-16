import EdithExtensionSupport
import Foundation

public struct QuinjetManagedOSC: Sendable {
    private var pending = Data()
    private var escape = false
    private var collecting = false
    public init() {}
    public mutating func append(_ bytes: Data) -> [String] {
        var actions: [String] = []
        for byte in bytes {
            if collecting {
                if byte == 7 || (escape && byte == 92) {
                    if escape { pending.removeLast() }
                    if let text = String(data: pending, encoding: .utf8), text.hasPrefix("6973;"),
                        QuinjetHostAction(payload: String(text.dropFirst(5))) != nil
                    {
                        actions.append(String(text.dropFirst(5)))
                    }
                    pending.removeAll(keepingCapacity: true)
                    collecting = false
                    escape = false
                } else if pending.count >= 512 {
                    pending.removeAll(keepingCapacity: true)
                    collecting = false
                    escape = false
                } else {
                    pending.append(byte)
                    escape = byte == 27
                }
            } else if escape && byte == 93 {
                collecting = true
                escape = false
                pending.removeAll(keepingCapacity: true)
            } else {
                escape = byte == 27
            }
        }
        return actions
    }
}

final class QuinjetManagedOSCRelay {
    private var parser = QuinjetManagedOSC()
    func append(_ bytes: Data) {
        guard let tab = ProcessInfo.processInfo.environment["EDITH_QUINJET_TAB_ID"],
            UUID(uuidString: tab) != nil,
            let endpoint = ExtensionPeerEndpoint.current(owner: "quinjet")
        else { return }
        for action in parser.append(bytes).prefix(32) {
            let done = DispatchSemaphore(value: 0)
            let operation = Task.detached {
                defer { done.signal() }
                do {
                    let payload = try JSONSerialization.data(withJSONObject: [
                        "tabID": tab, "action": action,
                    ])
                    _ = try await endpoint.invoke(
                        "quinjet.native.action", payload: payload, timeout: 5)
                } catch {
                    FileHandle.standardError.write(
                        Data(
                            "The review action could not complete. Try it again in the review window.\n"
                                .utf8))
                }
            }
            if done.wait(timeout: .now() + 6) != .success { operation.cancel() }
        }
    }
}
