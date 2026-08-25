import Foundation

public enum HerdrAgentView: String, CaseIterable, Codable, Sendable {
    case agent
    case diff
    case split

    public var title: String {
        switch self {
        case .agent: "Open agent"
        case .diff: "Open diff"
        case .split: "Open split"
        }
    }

    public var shortTitle: String {
        switch self {
        case .agent: "Agent"
        case .diff: "Diff"
        case .split: "Split"
        }
    }

    public var icon: String {
        switch self {
        case .agent: "terminal"
        case .diff: "arrow.triangle.branch"
        case .split: "rectangle.split.2x1"
        }
    }

    public var showsAgent: Bool { self != .diff }

    public var showsDiff: Bool { self != .agent }
}

public enum HerdrSplitFraction {
    public static let key = AppStorageKeys.Herdr.splitFraction
    public static let minimum = 0.25
    public static let maximum = 0.8
    public static let standard = 0.58

    public static func clamp(_ value: Double) -> Double {
        min(maximum, max(minimum, value))
    }

    public static func fraction(
        for agentID: String, _ store: UserDefaults = SharedDefaults.store
    ) -> Double {
        let raw = (store.dictionary(forKey: key) as? [String: Double]) ?? [:]
        guard let value = raw[agentID] else { return standard }
        return clamp(value)
    }

    public static func set(
        _ fraction: Double, for agentID: String, _ store: UserDefaults = SharedDefaults.store
    ) {
        var raw = (store.dictionary(forKey: key) as? [String: Double]) ?? [:]
        raw[agentID] = clamp(fraction)
        store.set(raw, forKey: key)
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
