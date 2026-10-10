import Darwin
import EdithExtensionSupport
import Foundation

public enum MachineUsageFixtureSnapshot {
    public static func load(environment: [String: String] = ProcessInfo.processInfo.environment)
        throws -> Data
    {
        guard let path = environment["EDITH_EXTENSION_FIXTURE_HOME"], !path.isEmpty else {
            throw ExtensionPeerError.unavailable
        }
        let home = URL(fileURLWithPath: path).standardizedFileURL
        guard home != FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL else {
            throw ExtensionPeerError.invalidRequest
        }
        var directory = stat()
        guard lstat(home.path, &directory) == 0, directory.st_mode & S_IFMT == S_IFDIR,
            directory.st_uid == getuid()
        else { throw ExtensionPeerError.invalidRequest }
        let file = home.appendingPathComponent("machines-raw-snapshot.json")
        var metadata = stat()
        guard lstat(file.path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
            metadata.st_uid == getuid(), metadata.st_mode & 0o077 == 0,
            metadata.st_size > 0, metadata.st_size <= 67_108_864
        else {
            throw ExtensionPeerError.invalidRequest
        }
        let descriptor = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw ExtensionPeerError.invalidRequest }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0, opened.st_ino == metadata.st_ino,
            opened.st_dev == metadata.st_dev, opened.st_size == metadata.st_size,
            let data = try handle.read(upToCount: 67_108_865), data.count == metadata.st_size
        else {
            throw ExtensionPeerError.invalidRequest
        }
        try MachineUsageReceiptSnapshot.validate(data)
        return data
    }
}
