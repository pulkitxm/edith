import Foundation

public enum UsageCollector {
    public static let scriptName = "refresh-usage"

    public static func scriptURL() -> URL? {
        BundledResources.locate(scriptName, in: BundledResources.kitBundleName)
    }

    public static func script() -> Data? {
        guard let url = scriptURL() else { return nil }
        return try? Data(contentsOf: url)
    }

    public static var machinesDirectory: URL {
        Repo.dataDir.appendingPathComponent("machines")
    }

    public static func machineFile(id: UUID, in directory: URL = machinesDirectory) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }
}
