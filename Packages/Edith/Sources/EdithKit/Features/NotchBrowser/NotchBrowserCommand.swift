import Foundation

public enum NotchBrowserIPC {
    public static let requestKey = "request"
    public static let requestIDKey = "requestID"
    public static let deadlineKey = "deadline"
    public static let snapshotKey = "snapshot"
    public static let okKey = "ok"
    public static let errorKey = "error"
}

public struct NotchBrowserProfileState: Codable, Equatable, Sendable {
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public struct NotchBrowserTabState: Codable, Equatable, Sendable {
    public var id: String
    public var index: Int
    public var title: String
    public var url: String?
    public var selected: Bool
    public var loading: Bool

    public init(
        id: String, index: Int, title: String, url: String?, selected: Bool, loading: Bool
    ) {
        self.id = id
        self.index = index
        self.title = title
        self.url = url
        self.selected = selected
        self.loading = loading
    }
}

public struct NotchBrowserSnapshot: Codable, Equatable, Sendable {
    public var attached: Bool
    public var profile: NotchBrowserProfileState?
    public var profiles: [NotchBrowserProfileState]
    public var tabs: [NotchBrowserTabState]
    public var sync: String
    public var canReopen: Bool
    public var link: String?
    public var message: String?

    public init(
        attached: Bool, profile: NotchBrowserProfileState?, profiles: [NotchBrowserProfileState],
        tabs: [NotchBrowserTabState], sync: String, canReopen: Bool, link: String? = nil,
        message: String? = nil
    ) {
        self.attached = attached
        self.profile = profile
        self.profiles = profiles
        self.tabs = tabs
        self.sync = sync
        self.canReopen = canReopen
        self.link = link
        self.message = message
    }

    public var encoded: String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    public static func decode(_ text: String?) -> NotchBrowserSnapshot? {
        guard let text else { return nil }
        return try? JSONDecoder().decode(NotchBrowserSnapshot.self, from: Data(text.utf8))
    }

    public func resultPayload(requestID: String?, error: String? = nil) -> [String: Any] {
        var payload: [String: Any] = [NotchBrowserIPC.okKey: error == nil]
        if let requestID { payload[NotchBrowserIPC.requestIDKey] = requestID }
        if let encoded { payload[NotchBrowserIPC.snapshotKey] = encoded }
        if let error { payload[NotchBrowserIPC.errorKey] = error }
        return payload
    }
}

public enum NotchBrowserRequest: Codable, Equatable, Sendable {
    case status
    case navigate(String, tab: String?)
    case reload(hard: Bool, tab: String?)
    case copyLink(tab: String?)
    case close(tab: String?)
    case closeOthers(tab: String?)
    case closeRight(tab: String?)
    case reopen
    case duplicate(tab: String?)
    case sync
    case profile(String)
    case detach
    case newTab(String?)

    public var encoded: String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    public static func decode(_ text: String) -> NotchBrowserRequest? {
        try? JSONDecoder().decode(NotchBrowserRequest.self, from: Data(text.utf8))
    }
}

public struct NotchBrowserRuntimeRequest: Equatable, Sendable {
    public let request: NotchBrowserRequest
    public let requestID: String
    public let deadline: Date

    public init(
        request: NotchBrowserRequest, requestID: String = UUID().uuidString, deadline: Date
    ) {
        self.request = request
        self.requestID = requestID
        self.deadline = deadline
    }

    public init?(payload: [AnyHashable: Any]) {
        guard let text = payload[NotchBrowserIPC.requestKey] as? String,
            let request = NotchBrowserRequest.decode(text),
            let requestID = payload[NotchBrowserIPC.requestIDKey] as? String,
            UUID(uuidString: requestID) != nil,
            let deadline = payload[NotchBrowserIPC.deadlineKey] as? TimeInterval, deadline.isFinite
        else { return nil }
        self.init(
            request: request, requestID: requestID, deadline: Date(timeIntervalSince1970: deadline))
    }

    public var payload: [String: Any]? {
        guard let encoded = request.encoded else { return nil }
        return [
            NotchBrowserIPC.requestKey: encoded,
            NotchBrowserIPC.requestIDKey: requestID,
            NotchBrowserIPC.deadlineKey: deadline.timeIntervalSince1970,
        ]
    }

    public func isLive(at now: Date = Date()) -> Bool { now < deadline }
}
