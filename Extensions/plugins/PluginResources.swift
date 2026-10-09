import Foundation

private final class PluginResourceMarker: NSObject {}

enum PluginResources {
    static func url(forResource name: String, withExtension suffix: String) -> URL? {
        #if SWIFT_PACKAGE
        return Bundle.module.url(forResource: name, withExtension: suffix)
        #else
        return Bundle(for: PluginResourceMarker.self).url(forResource: name, withExtension: suffix)
        #endif
    }
}
