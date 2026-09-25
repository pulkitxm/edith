import Foundation

public enum AppBuildIdentity {
    public static let production = "com.pulkit.edith"
    public static let developmentPrefix = production + ".dev."
    public static let developmentDirectoryName = "Edith Dev"

    public static let application = resolve(bundleURL: Bundle.main.bundleURL)

    public static var isDevelopment: Bool { application != production }
    public static var developmentSlot: String? { slot(of: application) }
    public static var helper: String {
        isDevelopment ? application + ".helper" : production + ".helper.v2"
    }
    public static var agent: String { application + ".agent" }
    public static var sharedDefaults: String { application + ".shared" }
    public static var directoryName: String { directoryName(for: application) }

    public static func keychainService(_ name: String) -> String {
        application + "." + name
    }

    public static func slot(of identifier: String) -> String? {
        guard identifier != production else { return nil }
        if identifier.hasPrefix(developmentPrefix) {
            return String(identifier.dropFirst(developmentPrefix.count))
        }
        return String(identifier.dropFirst(production.count + 1))
    }

    public static func directoryName(for identifier: String) -> String {
        slot(of: identifier).map { developmentDirectoryName + "/" + $0 } ?? "Edith"
    }

    public static func resolve(bundleURL: URL) -> String {
        var candidate = bundleURL.standardizedFileURL
        var outermost: String?
        while candidate.path != "/" {
            if candidate.pathExtension == "app",
                let identifier = Bundle(url: candidate)?.bundleIdentifier
            {
                outermost = identifier
            }
            candidate.deleteLastPathComponent()
        }
        guard let outermost, outermost.hasPrefix(production + ".") else { return production }
        return outermost
    }
}
