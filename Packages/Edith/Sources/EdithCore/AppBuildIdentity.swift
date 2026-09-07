import Foundation

public enum AppBuildIdentity {
    public static let production = "com.pulkit.edith"
    public static let development = "com.pulkit.edith.development"

    public static let isDevelopment = resolve(bundleURL: Bundle.main.bundleURL)

    public static var application: String { isDevelopment ? development : production }
    public static var helper: String {
        isDevelopment ? development + ".helper" : production + ".helper.v2"
    }
    public static var agent: String { application + ".agent" }
    public static var sharedDefaults: String { application + ".shared" }
    public static var directoryName: String { isDevelopment ? "Edith Development" : "Edith" }

    public static func resolve(bundleURL: URL) -> Bool {
        var candidate = bundleURL.standardizedFileURL
        while candidate.path != "/" {
            if candidate.pathExtension == "app",
                let bundle = Bundle(url: candidate),
                let identifier = bundle.bundleIdentifier
            {
                return identifier == development || identifier.hasPrefix(development + ".")
            }
            candidate.deleteLastPathComponent()
        }
        return false
    }
}
