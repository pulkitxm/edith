import AppKit
import Foundation

public enum QuinjetResources {
    private final class Marker: NSObject {}
    public static var reviewURL: URL? {
        #if SWIFT_PACKAGE
        Bundle.module.url(forResource: "review", withExtension: "html")
        #else
        Bundle(for: Marker.self).url(forResource: "review", withExtension: "html")
        #endif
    }
}
