import AppKit
import Foundation
public enum HerdrResources {
    private final class Marker: NSObject {}
    public static func url(forResource name: String, withExtension kind: String) -> URL? {
        #if SWIFT_PACKAGE
        return Bundle.module.url(forResource: name, withExtension: kind)
        #else
        return Bundle(for: Marker.self).url(forResource: name, withExtension: kind)
        #endif
    }
}
public enum ProviderLogo {
    public static func image(named name: String) -> NSImage? {
        guard let url = HerdrResources.url(forResource: name, withExtension: "svg"),
            let image = NSImage(contentsOf: url)
        else { return nil }
        image.isTemplate = true; return image
    }
}
