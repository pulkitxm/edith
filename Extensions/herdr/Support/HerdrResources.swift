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
    private static let images = NSCache<NSString, NSImage>()

    public static func image(named name: String) -> NSImage? {
        if let cached = images.object(forKey: name as NSString) { return cached }
        guard let url = HerdrResources.url(forResource: name, withExtension: "svg"),
            let image = NSImage(contentsOf: url)
        else { return nil }
        image.isTemplate = true
        images.setObject(image, forKey: name as NSString)
        return image
    }
}
