import Darwin
import Foundation

enum AttentionArchiveCopy {
    private struct Budget {
        var entries = 0
        var bytes = 0
        let deadline = ContinuousClock.now.advanced(by: .seconds(60))

        mutating func visit() throws {
            entries += 1
            try check()
        }

        func check() throws {
            try Task.checkCancellation()
            guard entries <= 4096, bytes <= 536_870_912, ContinuousClock.now < deadline else {
                throw AttentionArchiveError.limit
            }
        }
    }

    static func copy(from source: URL, to destination: URL) throws {
        try Task.checkCancellation()
        let input = open(source.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        if input < 0, errno == ENOENT { return }
        guard input >= 0 else { throw AttentionArchiveError.unsafe }
        defer { close(input) }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let output = open(destination.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard output >= 0 else { throw AttentionArchiveError.unsafe }
        defer { close(output) }
        var budget = Budget()
        try copyDirectory(input, to: output, depth: 0, budget: &budget)
    }

    private static func copyDirectory(
        _ source: Int32, to destination: Int32, depth: Int, budget: inout Budget
    ) throws {
        guard depth <= 16 else { throw AttentionArchiveError.limit }
        let listing = openat(source, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard listing >= 0, let directory = fdopendir(listing) else {
            if listing >= 0 { close(listing) }
            throw AttentionArchiveError.unsafe
        }
        defer { closedir(directory) }
        while true {
            errno = 0
            guard let entry = readdir(directory) else {
                if errno != 0 { throw AttentionArchiveError.unsafe }
                return
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(cString: $0)
                }
            }
            guard name != ".", name != ".." else { continue }
            try budget.visit()
            guard !name.hasPrefix(".") else { continue }
            var metadata = stat()
            guard fstatat(source, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0 else {
                throw AttentionArchiveError.unsafe
            }
            switch metadata.st_mode & S_IFMT {
            case S_IFDIR:
                let child = openat(source, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
                guard child >= 0 else { throw AttentionArchiveError.unsafe }
                defer { close(child) }
                guard mkdirat(destination, name, 0o700) == 0 || errno == EEXIST else {
                    throw AttentionArchiveError.unsafe
                }
                let target = openat(
                    destination, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
                guard target >= 0 else { throw AttentionArchiveError.unsafe }
                defer { close(target) }
                try copyDirectory(child, to: target, depth: depth + 1, budget: &budget)
            case S_IFREG:
                try copyFile(name, from: source, to: destination, budget: &budget)
            case S_IFLNK:
                continue
            default:
                throw AttentionArchiveError.unsafe
            }
        }
    }

    private static func copyFile(
        _ name: String, from source: Int32, to destination: Int32, budget: inout Budget
    ) throws {
        let input = openat(source, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard input >= 0 else { throw AttentionArchiveError.unsafe }
        let reader = FileHandle(fileDescriptor: input, closeOnDealloc: true)
        defer { try? reader.close() }
        var metadata = stat()
        guard fstat(input, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG else {
            throw AttentionArchiveError.unsafe
        }
        guard metadata.st_size >= 0, metadata.st_size <= 67_108_864 else {
            throw AttentionArchiveError.limit
        }
        let temporary = ".attention-\(UUID().uuidString)"
        let output = openat(
            destination, temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard output >= 0 else { throw AttentionArchiveError.unsafe }
        let writer = FileHandle(fileDescriptor: output, closeOnDealloc: true)
        defer {
            try? writer.close()
            _ = unlinkat(destination, temporary, 0)
        }
        var copied = 0
        while true {
            try budget.check()
            guard let chunk = try reader.read(upToCount: 65_536), !chunk.isEmpty else { break }
            copied += chunk.count
            budget.bytes += chunk.count
            guard copied <= 67_108_864 else { throw AttentionArchiveError.limit }
            try budget.check()
            try writer.write(contentsOf: chunk)
        }
        try writer.synchronize()
        try Task.checkCancellation()
        guard renameat(destination, temporary, destination, name) == 0 else {
            throw AttentionArchiveError.unsafe
        }
    }
}

enum AttentionArchiveError: LocalizedError {
    case limit
    case unsafe

    var errorDescription: String? {
        switch self {
        case .limit:
            "Attention archives allow 4096 entries, 16 directory levels, 64 MiB per file and 512 MiB total within 60 seconds."
        case .unsafe:
            "The Attention archive contains an unreadable or unsupported file."
        }
    }
}
