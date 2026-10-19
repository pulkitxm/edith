import Darwin
import Foundation

enum OwnedAccountFiles {
    static let maximumBytes = 65_536

    static func components(_ url: URL) throws -> [String] {
        let path = url.path
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard url.isFileURL, path.hasPrefix("/"), path.utf8.count <= 8192,
            !path.utf8.contains(0), parts.count > 1,
            parts.dropFirst().allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else { throw ClaudeAccountError.invalidRequest }
        return parts.dropFirst().map(String.init)
    }

    static func root(_ url: URL) throws -> Int32 {
        let names = try components(url)
        var parent = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard parent >= 0 else { throw ClaudeAccountError.invalidRequest }
        do {
            for (index, name) in names.enumerated() {
                var next = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if next < 0, errno == ENOENT, index == names.count - 1 {
                    guard mkdirat(parent, name, 0o700) == 0 || errno == EEXIST else {
                        throw ClaudeAccountError.invalidRequest
                    }
                    next = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                }
                guard next >= 0 else { throw ClaudeAccountError.invalidRequest }
                close(parent)
                parent = next
            }
            try validate(parent, directory: true, privateMode: 0o700)
            return parent
        } catch {
            close(parent)
            throw error
        }
    }

    static func validate(_ descriptor: Int32, directory: Bool, privateMode: mode_t? = nil) throws {
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_uid == getuid(),
            info.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG),
            directory || info.st_nlink == 1,
            privateMode.map({ info.st_mode & 0o777 == $0 }) ?? true
        else { throw ClaudeAccountError.invalidRequest }
    }

    static func createProfile(_ id: UUID, root: Int32) throws {
        guard mkdirat(root, id.uuidString, 0o700) == 0 else {
            throw ClaudeAccountError.invalidRequest
        }
        guard let descriptor = try profile(id, root: root, create: false) else {
            throw ClaudeAccountError.invalidRequest
        }
        close(descriptor)
    }

    static func profile(_ id: UUID, root: Int32, create: Bool) throws -> Int32? {
        let name = id.uuidString
        var descriptor = openat(root, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if descriptor < 0, errno == ENOENT {
            guard create else { return nil }
            guard mkdirat(root, name, 0o700) == 0 || errno == EEXIST else {
                throw ClaudeAccountError.invalidRequest
            }
            descriptor = openat(root, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else { throw ClaudeAccountError.invalidRequest }
        do { try validate(descriptor, directory: true, privateMode: 0o700) } catch {
            close(descriptor)
            throw error
        }
        return descriptor
    }

    static func read(_ name: String, directory: Int32, maximum: Int = maximumBytes) throws -> Data?
    {
        let descriptor = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if descriptor < 0, errno == ENOENT { return nil }
        guard descriptor >= 0 else { throw ClaudeAccountError.invalidRequest }
        defer { close(descriptor) }
        try validate(descriptor, directory: false, privateMode: 0o600)
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_size >= 0, info.st_size <= maximum else {
            throw ClaudeAccountError.invalidRequest
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            try Task.checkCancellation()
            let limit = min(buffer.count, maximum + 1 - data.count)
            let count = Darwin.read(descriptor, &buffer, limit)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw ClaudeAccountError.invalidRequest }
            if count == 0 { return data }
            data.append(contentsOf: buffer.prefix(count))
            guard data.count <= maximum else { throw ClaudeAccountError.invalidRequest }
        }
    }

    static func write(
        _ data: Data, name: String, directory: Int32, mode: mode_t = 0o600, exclusive: Bool = false
    ) throws {
        guard data.count <= maximumBytes else { throw ClaudeAccountError.invalidRequest }
        try Task.checkCancellation()
        try validateExisting(name, directory: directory)
        let temporary = ".write-" + UUID().uuidString
        let descriptor = openat(
            directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode)
        guard descriptor >= 0 else { throw ClaudeAccountError.invalidRequest }
        defer { close(descriptor); unlinkat(directory, temporary, 0) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                try Task.checkCancellation()
                let count = Darwin.write(
                    descriptor, bytes.baseAddress!.advanced(by: offset),
                    min(4096, bytes.count - offset))
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw ClaudeAccountError.invalidRequest }
                offset += count
            }
        }
        guard fchmod(descriptor, mode) == 0, fsync(descriptor) == 0 else {
            throw ClaudeAccountError.invalidRequest
        }
        try Task.checkCancellation()
        try validateExisting(name, directory: directory)
        let committed =
            exclusive
            ? linkat(directory, temporary, directory, name, 0)
            : renameat(directory, temporary, directory, name)
        guard committed == 0 else {
            throw ClaudeAccountError.invalidRequest
        }
    }

    static func validateExisting(_ name: String, directory: Int32) throws {
        var info = stat()
        let found = fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW)
        if found != 0, errno == ENOENT { return }
        guard found == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG,
            info.st_mode & 0o077 == 0
        else { throw ClaudeAccountError.invalidRequest }
    }

    static func removeStale(prefix: String, olderThan age: TimeInterval, directory: Int32) throws {
        let copied = dup(directory)
        guard copied >= 0 else { throw ClaudeAccountError.invalidRequest }
        guard let stream = fdopendir(copied) else {
            close(copied)
            throw ClaudeAccountError.invalidRequest
        }
        defer { closedir(stream) }
        let cutoff = Date().timeIntervalSince1970 - age
        var stale: [String] = []
        while let entry = readdir(stream) {
            let length = Int(entry.pointee.d_namlen) + 1
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: length) { String(cString: $0) }
            }
            guard name.hasPrefix(prefix) else { continue }
            var info = stat()
            guard fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
                info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG,
                TimeInterval(info.st_mtimespec.tv_sec) < cutoff
            else { continue }
            stale.append(name)
        }
        for name in stale { unlinkat(directory, name, 0) }
    }

    static func removeProfile(_ id: UUID, root: Int32) throws {
        guard let descriptor = try profile(id, root: root, create: false) else { return }
        defer { close(descriptor) }
        var budget = 4096
        try removeContents(descriptor, budget: &budget, depth: 0)
        guard unlinkat(root, id.uuidString, AT_REMOVEDIR) == 0 else {
            throw ClaudeAccountError.invalidRequest
        }
    }

    private static func removeContents(_ directory: Int32, budget: inout Int, depth: Int) throws {
        guard depth <= 32 else { throw ClaudeAccountError.invalidRequest }
        let copied = dup(directory)
        guard copied >= 0 else { throw ClaudeAccountError.invalidRequest }
        guard let stream = fdopendir(copied) else {
            close(copied)
            throw ClaudeAccountError.invalidRequest
        }
        defer { closedir(stream) }
        while let entry = readdir(stream) {
            let length = Int(entry.pointee.d_namlen) + 1
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: length) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            budget -= 1
            guard budget >= 0 else { throw ClaudeAccountError.invalidRequest }
            var info = stat()
            guard fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
                info.st_uid == getuid()
            else { throw ClaudeAccountError.invalidRequest }
            if info.st_mode & S_IFMT == S_IFDIR {
                let child = openat(directory, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard child >= 0 else { throw ClaudeAccountError.invalidRequest }
                defer { close(child) }
                try validate(child, directory: true)
                try removeContents(child, budget: &budget, depth: depth + 1)
                guard unlinkat(directory, name, AT_REMOVEDIR) == 0 else {
                    throw ClaudeAccountError.invalidRequest
                }
            } else {
                guard info.st_mode & S_IFMT == S_IFREG || info.st_mode & S_IFMT == S_IFLNK,
                    unlinkat(directory, name, 0) == 0
                else { throw ClaudeAccountError.invalidRequest }
            }
        }
    }
}
