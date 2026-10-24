import EdithExtensionSupport
import Foundation

public enum MusicEvents {
    public enum Name {
        public static let musicCommand = "music.command"
        public static let musicState = "music.state"
        public static let musicLevel = "music.level"
        public static let musicFolderChanged = "music.folderChanged"
        public static let musicFavouritesChanged = "music.favouritesChanged"
        public static let musicRevealFolder = "music.revealFolder"
        public static let requestMusicState = "music.requestState"
        public static let requestMusicLevels = "music.requestLevels"
        public static let nowPlayingCommand = "music.external.command"
        public static let nowPlayingState = "music.external.state"
        public static let requestNowPlayingState = "music.external.requestState"
    }

    private static var distributedNamespace: String? {
        ExtensionEnvironment.values["EDITH_APPLICATION_IDENTIFIER"]
    }

    private static let distributedRequestBridge: NSObjectProtocol? = {
        guard let namespace = distributedNamespace else { return nil }
        return DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(namespace + ".requestMusicState"), object: nil,
            queue: .main
        ) { _ in
            NotificationCenter.default.post(
                name: Notification.Name(Name.requestMusicState), object: nil)
        }
    }()

    private static let distributedFolderBridge: NSObjectProtocol? = {
        guard let namespace = distributedNamespace else { return nil }
        return DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(namespace + ".musicFolderChanged"), object: nil,
            queue: .main
        ) { _ in
            NotificationCenter.default.post(
                name: Notification.Name(Name.musicFolderChanged), object: nil)
        }
    }()

    public static func post(_ name: String, userInfo: [String: Any]? = nil) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: Notification.Name(name), object: nil, userInfo: userInfo)
        }
        if name == Name.musicState, let namespace = distributedNamespace {
            DistributedNotificationCenter.default().postNotificationName(
                Notification.Name(namespace + ".musicState"), object: nil, userInfo: userInfo,
                deliverImmediately: true)
        }
    }

    public static func observe(
        _ name: String, handler: @escaping () -> Void
    ) -> NSObjectProtocol {
        if name == Name.requestMusicState { _ = distributedRequestBridge }
        if name == Name.musicFolderChanged { _ = distributedFolderBridge }
        return NotificationCenter.default.addObserver(
            forName: Notification.Name(name), object: nil, queue: .main
        ) { _ in handler() }
    }

    public static func observe(
        _ name: String, info handler: @escaping ([AnyHashable: Any]) -> Void
    ) -> NSObjectProtocol {
        NotificationCenter.default.addObserver(
            forName: Notification.Name(name), object: nil, queue: .main
        ) { handler($0.userInfo ?? [:]) }
    }

    public static func stopObserving(_ observer: NSObjectProtocol) {
        NotificationCenter.default.removeObserver(observer)
    }
}
