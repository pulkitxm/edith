import Foundation

public enum AgentBuildStamp {
    public static let key = "installedBuild"

    public static func currentBuild(bundle: Bundle = .main) -> String {
        bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "development"
    }

    public static func executableURL(bundle: Bundle = .main) -> URL {
        bundle.bundleURL.appendingPathComponent("Contents/MacOS/\(AgentService.executableName)")
    }

    public static func stamp(
        build: String, bundlePath: String, executableModified: Date?, executableSize: Int?
    ) -> String {
        [
            build, bundlePath,
            executableModified.map { String(Int($0.timeIntervalSince1970)) } ?? "0",
            executableSize.map(String.init) ?? "0",
        ].joined(separator: "|")
    }

    public static func currentStamp(
        bundle: Bundle = .main, fileManager: FileManager = .default
    ) -> String {
        let executable = executableURL(bundle: bundle)
        let attributes = try? fileManager.attributesOfItem(atPath: executable.path)
        return stamp(
            build: currentBuild(bundle: bundle), bundlePath: bundle.bundleURL.path,
            executableModified: attributes?[.modificationDate] as? Date,
            executableSize: (attributes?[.size] as? NSNumber)?.intValue)
    }

    public static func hasChanged(
        defaults: UserDefaults = SharedDefaults.store, bundle: Bundle = .main,
        fileManager: FileManager = .default
    ) -> Bool {
        stampIsStale(
            recorded: defaults.string(forKey: key),
            current: currentStamp(bundle: bundle, fileManager: fileManager))
    }

    public static func stampIsStale(recorded: String?, current: String) -> Bool {
        guard let recorded else { return true }
        return recorded != current
    }

    public static func record(
        defaults: UserDefaults = SharedDefaults.store, bundle: Bundle = .main,
        fileManager: FileManager = .default
    ) {
        defaults.set(currentStamp(bundle: bundle, fileManager: fileManager), forKey: key)
    }
}
