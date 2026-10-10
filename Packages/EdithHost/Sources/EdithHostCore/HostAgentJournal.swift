import Darwin
import Foundation

struct HostAgentJournal: Sendable {
    let directory: URL
    private let device: dev_t
    private let inode: ino_t
    static let maximumFiles = 1024

    init(directory: URL) throws {
        let directory = directory.standardizedFileURL
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        self.directory = directory.resolvingSymlinksInPath()
        let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw Self.invalid() }
        defer { close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0, status.st_uid == geteuid(),
            status.st_mode & 0o777 == 0o700
        else { throw Self.invalid() }
        device = status.st_dev
        inode = status.st_ino
    }

    func files() throws -> [URL] {
        let descriptor = try openDirectory()
        defer { close(descriptor) }
        let duplicated = dup(descriptor)
        guard duplicated >= 0, let stream = fdopendir(duplicated) else {
            if duplicated >= 0 { close(duplicated) }
            throw Self.invalid()
        }
        defer { closedir(stream) }
        var files: [URL] = []
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) {
                    String(cString: $0)
                }
            }
            guard name != ".", name != ".." else { continue }
            guard files.count < Self.maximumFiles else { throw Self.invalid() }
            files.append(directory.appendingPathComponent(name))
        }
        return files
    }

    func read(_ name: String, maximumBytes: Int) throws -> Data {
        try Self.validateName(name)
        let parent = try openDirectory()
        defer { close(parent) }
        let descriptor = openat(parent, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw Self.invalid() }
        defer { close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0, Self.validFile(status), status.st_size >= 0,
            status.st_size <= maximumBytes
        else { throw Self.invalid() }
        var data = Data(count: Int(status.st_size))
        try data.withUnsafeMutableBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.read(
                    descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw Self.invalid() }
                offset += count
            }
        }
        var after = stat()
        var extra: UInt8 = 0
        guard fstat(descriptor, &after) == 0, after.st_size == status.st_size,
            after.st_mtimespec.tv_sec == status.st_mtimespec.tv_sec,
            after.st_mtimespec.tv_nsec == status.st_mtimespec.tv_nsec,
            Darwin.read(descriptor, &extra, 1) == 0
        else { throw Self.invalid() }
        return data
    }

    func write(_ data: Data, name: String, maximumBytes: Int) throws {
        try Self.validateName(name)
        guard data.count <= maximumBytes else { throw Self.invalid() }
        let parent = try openDirectory()
        defer { close(parent) }
        try validateExisting(name, parent: parent)
        let temporary = ".\(UUID().uuidString)"
        let descriptor = openat(
            parent, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw Self.invalid() }
        defer { close(descriptor); unlinkat(parent, temporary, 0) }
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(
                    descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw Self.invalid() }
                offset += count
            }
        }
        guard fsync(descriptor) == 0 else { throw Self.invalid() }
        try validateExisting(name, parent: parent)
        guard renameat(parent, temporary, parent, name) == 0, fsync(parent) == 0 else {
            throw Self.invalid()
        }
    }

    func remove(_ name: String) throws {
        try Self.validateName(name)
        let parent = try openDirectory()
        defer { close(parent) }
        try validateExisting(name, parent: parent)
        if unlinkat(parent, name, 0) != 0 && errno != ENOENT { throw Self.invalid() }
    }

    private func openDirectory() throws -> Int32 {
        let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw Self.invalid() }
        var status = stat()
        guard fstat(descriptor, &status) == 0, status.st_dev == device, status.st_ino == inode,
            status.st_uid == geteuid(), status.st_mode & 0o777 == 0o700
        else {
            close(descriptor)
            throw Self.invalid()
        }
        return descriptor
    }

    private func validateExisting(_ name: String, parent: Int32) throws {
        var status = stat()
        if fstatat(parent, name, &status, AT_SYMLINK_NOFOLLOW) == 0 {
            guard Self.validFile(status) else { throw Self.invalid() }
        } else if errno != ENOENT {
            throw Self.invalid()
        }
    }
    private static func validFile(_ status: stat) -> Bool {
        status.st_mode & S_IFMT == S_IFREG && status.st_uid == geteuid() && status.st_nlink == 1
            && status.st_mode & 0o777 == 0o600
    }
    private static func validateName(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.utf8.contains(0)
        else { throw invalid() }
    }
    private static func invalid() -> HostAgentCommandError {
        HostAgentCommandError(.refused, "The core command journal is unsafe or exceeds its limit.")
    }
}
