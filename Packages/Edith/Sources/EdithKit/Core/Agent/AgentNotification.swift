import Foundation

public struct AgentNotification: Codable, Equatable, Sendable {
    public static let identifierKey = "identifier"
    public static let titleKey = "title"
    public static let bodyKey = "body"

    public let identifier: String
    public let title: String
    public let body: String

    public init(identifier: String, title: String, body: String) {
        self.identifier = identifier
        self.title = title
        self.body = body
    }

    public init?(userInfo: [AnyHashable: Any]) {
        guard let identifier = userInfo[Self.identifierKey] as? String,
            let title = userInfo[Self.titleKey] as? String,
            let body = userInfo[Self.bodyKey] as? String
        else { return nil }
        self.init(identifier: identifier, title: title, body: body)
    }

    public var userInfo: [String: Any] {
        [Self.identifierKey: identifier, Self.titleKey: title, Self.bodyKey: body]
    }
}
