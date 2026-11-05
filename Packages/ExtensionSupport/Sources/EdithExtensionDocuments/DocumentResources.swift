import Foundation

private final class DocumentResourceMarker: NSObject {}

enum DocumentResources {
    private static let highlightName = "highlight.min.js"
    private static let highlightExtension = "lzma"

    static func highlightScript(in bundle: Bundle) throws -> String? {
        guard let url = bundle.url(forResource: highlightName, withExtension: highlightExtension)
        else { return nil }
        let compressed = try Data(contentsOf: url)
        let script = try (compressed as NSData).decompressed(using: .lzma) as Data
        return String(data: script, encoding: .utf8)
    }

    static var bundle: Bundle? {
        let marker = Bundle(for: DocumentResourceMarker.self)
        if marker.url(forResource: highlightName, withExtension: highlightExtension) != nil {
            return marker
        }
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
                atPath: directory.appendingPathComponent(
                    "\(highlightName).\(highlightExtension)"
                ).path),
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
                    bundle.url(forResource: highlightName, withExtension: highlightExtension)
                        != nil
                {
                    return bundle
                }
            }
        }
        return nil
    }
}
