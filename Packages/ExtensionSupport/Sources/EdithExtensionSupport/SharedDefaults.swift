import Foundation

public enum SharedDefaults {
    public static let systemAppearanceKey = "AppleInterfaceStyle"

    public static func applicationStore(identifier: String) -> UserDefaults? {
        if identifier == "com.pulkit.edith" {
            return UserDefaults(suiteName: identifier + ".shared")
        }
        if Bundle.main.bundleIdentifier == identifier { return .standard }
        return UserDefaults(suiteName: identifier)
    }

    public static func resolvedSuite(environment: [String: String], applicationIdentifier: String?)
        -> String?
    {
        if let suite = environment["EDITH_SHARED_DEFAULTS_SUITE"] { return suite }
        return applicationIdentifier == "com.pulkit.edith" ? "com.pulkit.edith.shared" : nil
    }

    public static let store: UserDefaults = {
        guard
            let suite = resolvedSuite(
                environment: ProcessInfo.processInfo.environment,
                applicationIdentifier: Bundle.main.bundleIdentifier),
            let defaults = UserDefaults(suiteName: suite)
        else { return .standard }
        return defaults
    }()
}

public enum IPC {
    public enum Name {
        public static let emojiUsageChanged = "emojiUsageChanged"
        public static let requestEmojiPanel = "requestEmojiPanel"
        public static let requestEmojiInsert = "requestEmojiInsert"
        public static let emojiInsertResult = "emojiInsertResult"
        public static let settingsChanged = "settingsChanged"
        public static let requestColorPick = "requestColorPick"
        public static let presenterPauseAuto = "presenterPauseAuto"
        public static let presenterAutoActiveChanged = "presenterAutoActiveChanged"
    }

    public static func post(_ name: String, userInfo: [String: Any]? = nil) {
        NotificationCenter.default.post(
            name: Notification.Name(name), object: nil, userInfo: userInfo)
    }

    public static func observe(_ name: String, _ action: @escaping () -> Void) -> NSObjectProtocol {
        NotificationCenter.default.addObserver(
            forName: Notification.Name(name), object: nil, queue: .main
        ) { _ in action() }
    }

    public static func stopObserving(_ observer: NSObjectProtocol?) {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }
}
