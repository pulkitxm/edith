import Foundation

public enum MachinePaths {
    nonisolated(unsafe) public static var root: URL = AppData.supportDir

    public static var dir: URL {
        root.appendingPathComponent("machines")
    }

    public static var machinesFile: URL { dir.appendingPathComponent("machines.json") }
    public static var forwardsFile: URL { dir.appendingPathComponent("forwards.json") }
    public static var snippetsFile: URL { dir.appendingPathComponent("snippets.json") }
    public static var knownHostsFile: URL { dir.appendingPathComponent("known_hosts") }
    public static var socketsDir: URL { dir.appendingPathComponent("sockets") }

    public static var previewCacheDir: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Edith/MachinePreviews")
    }

    public static func prepare() {
        let fm = FileManager.default
        try? fm.createDirectory(
            at: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try? fm.createDirectory(
            at: socketsDir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try? fm.createDirectory(at: previewCacheDir, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: knownHostsFile.path) {
            fm.createFile(
                atPath: knownHostsFile.path, contents: Data(),
                attributes: [.posixPermissions: 0o600])
        }
    }

    public static func socketFile(for machineID: UUID) -> URL {
        let hash = machineID.uuidString.replacingOccurrences(of: "-", with: "").prefix(10)
        return socketsDir.appendingPathComponent("\(hash).sk")
    }
}
