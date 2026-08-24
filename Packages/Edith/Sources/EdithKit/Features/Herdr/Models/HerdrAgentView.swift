import Foundation

public enum HerdrAgentView: String, CaseIterable, Codable, Sendable {
    case agent
    case diff

    public var title: String {
        switch self {
        case .agent: "Open agent"
        case .diff: "Open diff"
        }
    }

    public var icon: String {
        switch self {
        case .agent: "terminal"
        case .diff: "arrow.triangle.branch"
        }
    }
}

public enum HerdrAgentViews {
    public static let key = AppStorageKeys.Herdr.agentViews

    public static func stored(_ store: UserDefaults = SharedDefaults.store) -> [String:
        HerdrAgentView]
    {
        let raw = (store.dictionary(forKey: key) as? [String: String]) ?? [:]
        return raw.compactMapValues(HerdrAgentView.init(rawValue:))
    }

    public static func view(for agentID: String, _ store: UserDefaults = SharedDefaults.store)
        -> HerdrAgentView
    {
        stored(store)[agentID] ?? .agent
    }

    public static func set(
        _ view: HerdrAgentView, for agentID: String,
        _ store: UserDefaults = SharedDefaults.store
    ) {
        var raw = (store.dictionary(forKey: key) as? [String: String]) ?? [:]
        if view == .agent {
            raw.removeValue(forKey: agentID)
        } else {
            raw[agentID] = view.rawValue
        }
        if raw.isEmpty {
            store.removeObject(forKey: key)
        } else {
            store.set(raw, forKey: key)
        }
    }

    public static func forget(_ agentID: String, _ store: UserDefaults = SharedDefaults.store) {
        set(.agent, for: agentID, store)
    }
}
