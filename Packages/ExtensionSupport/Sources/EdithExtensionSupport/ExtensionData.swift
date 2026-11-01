import Foundation

public enum ExtensionData {
    private static let temporaryRoot = ExtensionScope.temporaryDataRoot()

    public static var root: URL {
        resolve(environment: ExtensionEnvironment.values, fallback: temporaryRoot)
    }

    public static var productionBases: [String: String] { ExtensionDataLayout.productionBases }

    public static var productionLeaves: [String: [String]] { ExtensionDataLayout.productionLeaves }

    public static func selectedMusicDirectory(defaults: UserDefaults, homeDirectory: URL) -> URL? {
        ExtensionDataLayout.selectedMusicDirectory(defaults: defaults, homeDirectory: homeDirectory)
    }

    public static func productionDirectory(
        _ relative: String, fallback: URL,
        environment: [String: String] = ExtensionEnvironment.values
    ) -> URL {
        ExtensionDataLayout.productionDirectory(
            relative, fallback: fallback, environment: environment)
    }

    public static func resolve(environment: [String: String], fallback: URL) -> URL {
        ExtensionDataLayout.resolve(environment: environment, fallback: fallback)
    }
}
