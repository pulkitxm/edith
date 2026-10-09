import EdithExtensionSupport
import Foundation

public enum MusicReveal {
    public static let key = "musicRevealPath"

    @MainActor
    public static func request(trackPath: String) {
        let folder = (trackPath as NSString).deletingLastPathComponent
        SharedDefaults.store.set(folder, forKey: key)
        MusicEvents.post(MusicEvents.Name.musicRevealFolder, userInfo: ["path": folder])
    }

    public static func consumePending() -> String? {
        guard let path = SharedDefaults.store.string(forKey: key) else { return nil }
        SharedDefaults.store.removeObject(forKey: key)
        return path
    }
}
