import Foundation

public struct HerdrOpenRequest: Codable, Equatable, Sendable {
    public var agentID: String
    public var hostID: String
    public var view: HerdrAgentView

    public init(agentID: String, hostID: String, view: HerdrAgentView) {
        self.agentID = agentID
        self.hostID = hostID
        self.view = view
    }
}

public enum HerdrOpenRequests {
    public static let lifetime: TimeInterval = 120

    private struct Pending: Codable {
        var request: HerdrOpenRequest
        var at: Date
    }

    public static func submit(
        _ request: HerdrOpenRequest, defaults: UserDefaults = SharedDefaults.store,
        now: Date = Date(), post: (Notification.Name) -> Void = { IPC.post($0) }
    ) {
        guard let data = try? JSONEncoder().encode(Pending(request: request, at: now)) else {
            return
        }
        defaults.set(data, forKey: AppStorageKeys.Herdr.pendingOpen)
        post(IPC.Name.requestOpenHerdrAgent)
    }

    public static func take(
        defaults: UserDefaults = SharedDefaults.store, now: Date = Date()
    ) -> HerdrOpenRequest? {
        guard let data = defaults.data(forKey: AppStorageKeys.Herdr.pendingOpen) else {
            return nil
        }
        defaults.removeObject(forKey: AppStorageKeys.Herdr.pendingOpen)
        guard let pending = try? JSONDecoder().decode(Pending.self, from: data),
            now.timeIntervalSince(pending.at) < lifetime
        else { return nil }
        return pending.request
    }
}
