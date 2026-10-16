import Foundation

private final class DocumentResourceMarker: NSObject {}

enum DocumentResources {
    static var bundle: Bundle? {
        let marker = Bundle(for: DocumentResourceMarker.self)
        if marker.url(forResource: "highlight.min", withExtension: "js") != nil { return marker }
        let loaded = Bundle.allBundles + Bundle.allFrameworks
        let directories =
            [
                Bundle(for: DocumentResourceMarker.self).resourceURL,
                Bundle.main.resourceURL,
                Bundle.main.bundleURL,
                Bundle.main.bundleURL.deletingLastPathComponent(),
                URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent(),
            ].compactMap { $0 }
            + loaded.flatMap { [$0.bundleURL, $0.bundleURL.deletingLastPathComponent()] }
        for directory in directories {
            if FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("highlight.min.js").path),
                let bundle = Bundle(url: directory)
            {
                return bundle
            }
            let children =
                (try? FileManager.default.contentsOfDirectory(
                    at: directory, includingPropertiesForKeys: nil)) ?? []
            for child in children
            where child.lastPathComponent.hasPrefix("ExtensionSupport_")
                && child.pathExtension == "bundle"
            {
                if let bundle = Bundle(url: child),
                    bundle.url(forResource: "highlight.min", withExtension: "js") != nil
                {
                    return bundle
                }
            }
        }
        return nil
    }
}
