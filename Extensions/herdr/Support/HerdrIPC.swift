import Foundation

public enum HerdrIPC {
    public enum Name {
        public static let herdrLayoutActionResult = Notification.Name(
            "herdr.herdrLayoutActionResult")
        public static let herdrSpaceActionResult = Notification.Name("herdr.herdrSpaceActionResult")
        public static let machinesChanged = Notification.Name("herdr.machinesChanged")
        public static let requestHerdrLayoutAction = Notification.Name(
            "herdr.requestHerdrLayoutAction")
        public static let requestHerdrSpaceAction = Notification.Name(
            "herdr.requestHerdrSpaceAction")
        public static let requestOpenHerdrAgent = Notification.Name("herdr.requestOpenHerdrAgent")
    }
    public static func post(_ name: Notification.Name, userInfo: [String: Any]? = nil) {
        NotificationCenter.default.post(name: name, object: nil, userInfo: userInfo)
    }
    public static func observe(_ name: Notification.Name, _ action: @escaping () -> Void)
        -> NSObjectProtocol
    {
        NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
            action()
        }
    }
    public static func observe(
        _ name: Notification.Name, _ action: @escaping (Notification) -> Void
    ) -> NSObjectProtocol {
        NotificationCenter.default.addObserver(
            forName: name, object: nil, queue: .main, using: action)
    }
    public static func stopObserving(_ observer: NSObjectProtocol?) {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }
}
