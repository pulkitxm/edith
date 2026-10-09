import Foundation

public enum BifrostIPC {
    public enum Name {
        public static let settingsChanged = Notification.Name(
            "com.pulkit.edith.bifrost.settingsChanged")
        public static let requestBifrostPanel = Notification.Name(
            "com.pulkit.edith.bifrost.requestBifrostPanel")
        public static let requestBifrostReindex = Notification.Name(
            "com.pulkit.edith.bifrost.requestBifrostReindex")
        public static let bifrostIndexChanged = Notification.Name(
            "com.pulkit.edith.bifrost.bifrostIndexChanged")
        public static let requestClipboardPanel = Notification.Name(
            "com.pulkit.edith.bifrost.requestClipboardPanel")
        public static let requestEmojiPanel = Notification.Name(
            "com.pulkit.edith.bifrost.requestEmojiPanel")
        public static let requestColorPick = Notification.Name(
            "com.pulkit.edith.bifrost.requestColorPick")
        public static let openPanel = Notification.Name("com.pulkit.edith.bifrost.openPanel")
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

    public static func stopObserving(_ observer: NSObjectProtocol) {
        NotificationCenter.default.removeObserver(observer)
    }
}
