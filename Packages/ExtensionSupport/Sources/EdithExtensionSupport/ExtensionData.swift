import Foundation

public enum ExtensionData {
    private static let temporaryRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("edith-extension-\(UUID().uuidString)", isDirectory: true)

    public static var root: URL {
        resolve(environment: ProcessInfo.processInfo.environment, fallback: temporaryRoot)
    }

    public static func resolve(environment: [String: String], fallback: URL) -> URL {
        guard let path = environment["EDITH_EXTENSION_DATA_ROOT"], path.hasPrefix("/"),
            !path.utf8.contains(0)
        else { return fallback }
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    }
}
