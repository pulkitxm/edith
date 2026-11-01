import EdithExtensionFiles
import EdithExtensionSupport
import CryptoKit
import Darwin
import Foundation

public enum MachinePaths {
    nonisolated(unsafe) public static var root: URL = ExtensionData.root {
        didSet { FileCachePaths.root = root }
    }

    public static var dir: URL {
        root
    }

    public static var machinesFile: URL { dir.appendingPathComponent("machines.json") }
    public static var forwardsFile: URL { dir.appendingPathComponent("forwards.json") }
    public static var snippetsFile: URL { dir.appendingPathComponent("snippets.json") }
    public static var knownHostsFile: URL { dir.appendingPathComponent("known_hosts") }
    public static var socketsDir: URL { socketDirectory(for: dir) }

    static func socketDirectory(for root: URL) -> URL {
        let directory = root.appendingPathComponent("sockets")
        if directory.appendingPathComponent("00000000-000000.sk").path.utf8.count < 104 {
            return directory
        }
        let digest = SHA256.hash(data: Data(root.standardizedFileURL.path.utf8))
            .prefix(12).map { String(format: "%02x", $0) }.joined()
        return URL(fileURLWithPath: "/tmp/edith-ssh-\(getuid())-\(digest)", isDirectory: true)
    }

    static func prepareSockets() throws {
        let path = socketsDir.path
        guard mkdir(path, 0o700) == 0 || errno == EEXIST else {
            throw CocoaError(.fileWriteNoPermission)
        }
        var metadata = stat()
        guard lstat(path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFDIR,
            metadata.st_uid == getuid(), metadata.st_mode & 0o077 == 0
        else { throw CocoaError(.fileWriteNoPermission) }
    }

    public static var previewCacheDir: URL {
        root.appendingPathComponent("previews")
    }

    public static func prepare() {
        let fm = FileManager.default
        try? fm.createDirectory(
            at: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try? prepareSockets()
        try? fm.createDirectory(at: previewCacheDir, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: knownHostsFile.path) {
            fm.createFile(
                atPath: knownHostsFile.path, contents: Data(),
                attributes: [.posixPermissions: 0o600])
        }
    }

    public static func socketFile(for machineID: UUID, connectionID: UUID? = nil) -> URL {
        let machineLength = connectionID == nil ? 10 : 8
        let hash = machineID.uuidString.replacingOccurrences(of: "-", with: "").prefix(
            machineLength)
        let connection =
            connectionID.map {
                "-" + $0.uuidString.replacingOccurrences(of: "-", with: "").prefix(6)
            } ?? ""
        return socketsDir.appendingPathComponent("\(hash)\(connection).sk")
    }
}
