import Foundation

private final class EmojiResourceMarker: NSObject {}

enum EmojiResources {
    static func url(forResource name: String, withExtension suffix: String) -> URL? {
        #if SWIFT_PACKAGE
        return Bundle.module.url(forResource: name, withExtension: suffix)
        #else
        return Bundle(for: EmojiResourceMarker.self).url(forResource: name, withExtension: suffix)
        #endif
    }
}
