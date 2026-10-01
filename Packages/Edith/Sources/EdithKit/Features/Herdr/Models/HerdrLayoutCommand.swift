import Foundation

public enum HerdrLayoutIPC {
    public static let requestKey = "request"
    public static let requestIDKey = "requestID"
    public static let deadlineKey = "deadline"
    public static let snapshotKey = "snapshot"
    public static let okKey = "ok"
    public static let errorKey = "error"
}

public struct HerdrLayoutAgentState: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var pane: String

    public init(id: String, title: String, pane: String) {
        self.id = id
        self.title = title
        self.pane = pane
    }
}

public struct HerdrLayoutTabState: Codable, Equatable, Sendable {
    public var id: String
    public var index: Int
    public var title: String
    public var agents: [HerdrLayoutAgentState]
    public var focused: String
    public var selected: Bool

    public init(
        id: String, index: Int, title: String, agents: [HerdrLayoutAgentState], focused: String,
        selected: Bool
    ) {
        self.id = id
        self.index = index
        self.title = title
        self.agents = agents
        self.focused = focused
        self.selected = selected
    }
}

public struct HerdrLayoutArrangementState: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var panes: Int

    public init(id: String, name: String, panes: Int) {
        self.id = id
        self.name = name
        self.panes = panes
    }
}

public struct HerdrLayoutTerminalState: Codable, Equatable, Sendable {
    public var id: String
    public var owner: String
    public var title: String
    public var selected: Bool

    public init(id: String, owner: String, title: String, selected: Bool) {
        self.id = id
        self.owner = owner
        self.title = title
        self.selected = selected
    }
}

public struct HerdrLayoutSnapshot: Codable, Equatable, Sendable {
    public var selected: String
    public var tabs: [HerdrLayoutTabState]
    public var arrangements: [HerdrLayoutArrangementState]
    public var agents: [HerdrLayoutAgentState]
    public var terminals: [HerdrLayoutTerminalState]
    public var message: String?

    public init(
        selected: String, tabs: [HerdrLayoutTabState],
        arrangements: [HerdrLayoutArrangementState], agents: [HerdrLayoutAgentState],
        terminals: [HerdrLayoutTerminalState], message: String? = nil
    ) {
        self.selected = selected
        self.tabs = tabs
        self.arrangements = arrangements
        self.agents = agents
        self.terminals = terminals
        self.message = message
    }

    public var encoded: String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    public static func decode(_ text: String?) -> HerdrLayoutSnapshot? {
        guard let text else { return nil }
        return try? JSONDecoder().decode(HerdrLayoutSnapshot.self, from: Data(text.utf8))
    }

    public func resultPayload(requestID: String?, error: String? = nil) -> [String: Any] {
        var payload: [String: Any] = [HerdrLayoutIPC.okKey: error == nil]
        if let requestID { payload[HerdrLayoutIPC.requestIDKey] = requestID }
        if let encoded { payload[HerdrLayoutIPC.snapshotKey] = encoded }
        if let error { payload[HerdrLayoutIPC.errorKey] = error }
        return payload
    }
}

public enum HerdrLayoutRequest: Codable, Equatable, Sendable {
    case status
    case closeTab(String)
    case closeOthers(String)
    case closeRight(String)
    case closeAll
    case gather(String)
    case separate(String)
    case split(agent: String, side: String)
    case move(agent: String, tab: String)
    case swap(String, String)
    case save(tab: String, name: String)
    case deleteLayout(String)
    case apply(tab: String, name: String)
    case even(String)
    case newTerminal(String)

    public var encoded: String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    public static func decode(_ text: String) -> HerdrLayoutRequest? {
        try? JSONDecoder().decode(HerdrLayoutRequest.self, from: Data(text.utf8))
    }
}

public struct HerdrLayoutRuntimeRequest: Equatable, Sendable {
    public let request: HerdrLayoutRequest
    public let requestID: String
    public let deadline: Date

    public init(
        request: HerdrLayoutRequest, requestID: String = UUID().uuidString, deadline: Date
    ) {
        self.request = request
        self.requestID = requestID
        self.deadline = deadline
    }

    public init?(payload: [AnyHashable: Any]) {
        guard let text = payload[HerdrLayoutIPC.requestKey] as? String,
            let request = HerdrLayoutRequest.decode(text),
            let requestID = payload[HerdrLayoutIPC.requestIDKey] as? String,
            UUID(uuidString: requestID) != nil,
            let deadline = payload[HerdrLayoutIPC.deadlineKey] as? TimeInterval, deadline.isFinite
        else { return nil }
        self.init(
            request: request, requestID: requestID,
            deadline: Date(timeIntervalSince1970: deadline))
    }

    public var payload: [String: Any]? {
        guard let encoded = request.encoded else { return nil }
        return [
            HerdrLayoutIPC.requestKey: encoded,
            HerdrLayoutIPC.requestIDKey: requestID,
            HerdrLayoutIPC.deadlineKey: deadline.timeIntervalSince1970,
        ]
    }

    public func isLive(at now: Date = Date()) -> Bool { now < deadline }
}
