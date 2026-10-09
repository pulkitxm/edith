import EdithExtensionSupport
import Foundation

public enum Repo {
    public static var dataDir: URL { ExtensionData.root.appendingPathComponent("data") }
    public static var usageJSON: URL { dataDir.appendingPathComponent("usage.json") }
    public static var limitsJSONL: URL { dataDir.appendingPathComponent("limits-history.jsonl") }
}

public enum MachineRegistry {
    public static func machines(
        file: URL = ExtensionData.root.deletingLastPathComponent().appendingPathComponent(
            "machines/machines.json")
    ) -> [Machine] {
        guard
            let metadata = try? file.resourceValues(forKeys: [
                .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
            ]),
            metadata.isRegularFile == true, metadata.isSymbolicLink != true,
            let size = metadata.fileSize, size <= 1_048_576,
            let data = try? Data(contentsOf: file), data.count <= 1_048_576,
            let machines = try? JSONDecoder().decode([Machine].self, from: data)
        else { return [] }
        return Array(machines.prefix(128))
    }
}
