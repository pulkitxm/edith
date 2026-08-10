import Foundation

private final class BundleToken {}

public enum BundledResources {
    public static let kitBundleName = "Edith_EdithKit"

    public static func url(
        forResource name: String, withExtension ext: String, in bundleName: String = kitBundleName
    ) -> URL? {
        locate("\(name).\(ext)", in: bundleName)
    }

    public static func locate(
        _ file: String, in bundleName: String, directories: [URL] = searchDirectories(),
        fileManager: FileManager = .default
    ) -> URL? {
        for directory in directories {
            let bundle = directory.appendingPathComponent("\(bundleName).bundle")
            for candidate in [
                bundle.appendingPathComponent(file),
                bundle.appendingPathComponent("Contents/Resources").appendingPathComponent(file),
            ] where fileManager.isReadableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    public static func bundle(
        named name: String, directories: [URL] = searchDirectories(),
        fileManager: FileManager = .default
    ) -> Bundle? {
        for directory in directories {
            let candidate = directory.appendingPathComponent("\(name).bundle")
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
                isDirectory.boolValue, let found = Bundle(url: candidate)
            else { continue }
            return found
        }
        return nil
    }

    public static func ownerBundle() -> Bundle { Bundle(for: BundleToken.self) }

    public static func searchDirectories(
        mainBundleURL: URL = Bundle.main.bundleURL,
        mainResourceURL: URL? = Bundle.main.resourceURL,
        ownerBundleURL: URL = ownerBundle().bundleURL,
        ownerResourceURL: URL? = ownerBundle().resourceURL
    ) -> [URL] {
        var directories: [URL] = []
        var seen: Set<String> = []
        func add(_ url: URL?) {
            guard let url else { return }
            guard seen.insert(url.standardizedFileURL.path).inserted else { return }
            directories.append(url)
        }
        add(mainResourceURL)
        add(mainBundleURL)
        add(mainBundleURL.deletingLastPathComponent().appendingPathComponent("Resources"))
        add(ownerResourceURL)
        add(ownerBundleURL)
        add(ownerBundleURL.deletingLastPathComponent())
        return directories
    }
}
