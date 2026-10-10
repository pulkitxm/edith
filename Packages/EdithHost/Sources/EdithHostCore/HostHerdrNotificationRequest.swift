import Foundation

public struct HostHerdrNotificationRequest: Codable, Equatable, Sendable {
    public enum View: String, Codable, Sendable { case agent, diff, split }
    public let agentID: String
    public let hostID: String
    public let view: View

    public init(userInfo: [AnyHashable: Any]) throws {
        let required = Set(["identifier", "title", "body", "agentID", "hostID", "view"])
        guard userInfo.count == required.count,
            Set(userInfo.keys.compactMap { $0 as? String }) == required,
            required.allSatisfy({ key in
                guard let value = userInfo[key] as? String else { return false }
                return value.utf8.count <= 4096 && !value.utf8.contains(0)
            }),
            let identifier = userInfo["identifier"] as? String, !identifier.isEmpty,
            let agentID = userInfo["agentID"] as? String, !agentID.isEmpty,
            let hostID = userInfo["hostID"] as? String, !hostID.isEmpty,
            let value = userInfo["view"] as? String, let view = View(rawValue: value)
        else { throw HostWorkerError.rejected }
        self.agentID = agentID; self.hostID = hostID; self.view = view
    }
}
