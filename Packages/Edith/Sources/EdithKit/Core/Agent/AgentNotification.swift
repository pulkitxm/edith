import Foundation

public struct AgentNotification: Codable, Equatable, Sendable {
    public static let identifierKey = "identifier"
    public static let titleKey = "title"
    public static let bodyKey = "body"
    public static let agentKey = "agentID"
    public static let hostKey = "hostID"
    public static let viewKey = "view"

    public let identifier: String
    public let title: String
    public let body: String
    public let action: HerdrOpenRequest?

    public init(
        identifier: String, title: String, body: String, action: HerdrOpenRequest? = nil
    ) {
        self.identifier = identifier
        self.title = title
        self.body = body
        self.action = action
    }

    public init?(userInfo: [AnyHashable: Any]) {
        guard let identifier = userInfo[Self.identifierKey] as? String,
            let title = userInfo[Self.titleKey] as? String,
            let body = userInfo[Self.bodyKey] as? String
        else { return nil }
        var action: HerdrOpenRequest?
        if let agentID = userInfo[Self.agentKey] as? String,
            let hostID = userInfo[Self.hostKey] as? String,
            let view = (userInfo[Self.viewKey] as? String).flatMap(HerdrAgentView.init)
        {
            action = HerdrOpenRequest(agentID: agentID, hostID: hostID, view: view)
        }
        self.init(identifier: identifier, title: title, body: body, action: action)
    }

    public var userInfo: [String: Any] {
        var info: [String: Any] = [
            Self.identifierKey: identifier, Self.titleKey: title, Self.bodyKey: body,
        ]
        if let action {
            info[Self.agentKey] = action.agentID
            info[Self.hostKey] = action.hostID
            info[Self.viewKey] = action.view.rawValue
        }
        return info
    }
}
