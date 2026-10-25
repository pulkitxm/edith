import Darwin
import EdithExtensionSupport
import Foundation

public enum Repo {
    public static var dataDir: URL { ExtensionData.root.appendingPathComponent("data") }
    public static var usageJSON: URL { dataDir.appendingPathComponent("usage.json") }
    public static var limitsJSONL: URL { dataDir.appendingPathComponent("limits-history.jsonl") }
}

public enum MachineRegistry {
    public static var machinesFile: URL {
        let root = ExtensionData.root
        if root.lastPathComponent == "Edith",
            ExtensionEnvironment.values["EDITH_APPLICATION_IDENTIFIER"]
                == "com.pulkit.edith"
        {
            return root.appendingPathComponent("machines/machines.json")
        }
        return root.deletingLastPathComponent().appendingPathComponent("machines/machines.json")
    }

    public static func machines(
        file: URL = machinesFile
    ) -> [Machine] {
        guard file.isFileURL else { return [] }
        let descriptor = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { return [] }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var metadata = stat()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
            metadata.st_uid == getuid(), metadata.st_size >= 0, metadata.st_size <= 1_048_576,
            let data = try? handle.read(upToCount: 1_048_577), data.count <= 1_048_576,
            let machines = try? decoder.decode([Machine].self, from: data)
        else { return [] }
        return Array(machines.prefix(128))
    }
}
