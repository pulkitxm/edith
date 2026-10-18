import Darwin
import Foundation

struct SEOAuditOwnedIO {
    static let maximumFileBytes = 64 * 1_024 * 1_024

    static func read(_ file: URL, root: URL, limit: Int = maximumFileBytes) -> Data? {
        guard contained(file, root: root), safeParents(file.deletingLastPathComponent(), root: root)
        else { return nil }
        let descriptor = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
            info.st_size >= 0, info.st_size <= limit
        else { return nil }
        var bytes = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, $0.count)
            }
            guard count >= 0 else { return nil }
            if count == 0 { return bytes }
            guard bytes.count <= limit - count else { return nil }
            bytes.append(contentsOf: buffer.prefix(count))
        }
    }

    static func write(_ data: Data, to file: URL, root: URL) throws {
        guard data.count <= maximumFileBytes, contained(file, root: root),
            safeParents(file.deletingLastPathComponent(), root: root)
        else { throw CocoaError(.fileWriteInvalidFileName) }
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        guard safeParents(file.deletingLastPathComponent(), root: root),
            (try? file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true
        else { throw CocoaError(.fileWriteInvalidFileName) }
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    static func contained(_ file: URL, root: URL) -> Bool {
        file.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/")
    }

    static func safeParents(_ directory: URL, root: URL) -> Bool {
        let root = root.standardizedFileURL
        var current = directory.standardizedFileURL
        guard current.path == root.path || contained(current, root: root) else { return false }
        while true {
            if (try? current.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                return false
            }
            if current.path == root.path { return true }
            current.deleteLastPathComponent()
        }
    }

}
