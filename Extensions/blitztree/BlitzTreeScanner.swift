import Darwin
import Foundation

enum BlitzTreeScanner {
    static let minimumBytes: UInt64 = 50_000_000
    static let resultLimit = 200
    static let datalessFlag: UInt32 = 0x4000_0000

    static func scan(
        root: String, minimumBytes: UInt64 = minimumBytes, limit: Int = resultLimit,
        isCancelled: () -> Bool = { Task.isCancelled },
        progress: BlitzTreeClient.Progress = { _ in }
    ) throws -> BlitzTreeReport {
        let started = ProcessInfo.processInfo.systemUptime
        let root = try resolvedDirectory(root)
        guard let name = strdup(root) else {
            throw BlitzTreeError.failed("Not enough memory to scan.")
        }
        defer { free(name) }
        let traversal = [name, nil].withUnsafeBufferPointer {
            fts_open($0.baseAddress, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil)
        }
        guard let traversal else { throw failure(root) }
        defer { fts_close(traversal) }
        var frames: [Folder] = []
        var children = LargestEntries(limit: limit)
        var directories = LargestEntries(limit: limit)
        var files = LargestEntries(limit: limit)
        var candidates = LargestEntries(limit: limit)
        var links = Set<FileIdentity>()
        var rootDevice: Int32 = 0
        var errors: UInt64 = 0
        var clouds: UInt64 = 0
        var mounts: UInt64 = 0
        var fileCount: UInt64 = 0
        var directoryCount: UInt64 = 0
        var candidateCount = 0
        var total: Folder?
        var lastProgress = started

        func finish() {
            guard let folder = frames.popLast() else { return }
            let entry = folder.entry
            if frames.isEmpty { total = folder; return }
            if frames.count == 1 { children.insert(entry) }
            if entry.allocatedBytes >= minimumBytes {
                directories.insert(entry)
                if folder.reason != nil {
                    candidates.insert(entry)
                    candidateCount += 1
                }
            }
            frames[frames.count - 1].allocated += folder.allocated
            frames[frames.count - 1].logical += folder.logical
            frames[frames.count - 1].files += folder.files
            frames[frames.count - 1].complete = frames.last!.complete && folder.complete
        }

        while true {
            if isCancelled() { throw CancellationError() }
            errno = 0
            guard let pointer = fts_read(traversal) else {
                if errno != 0 { errors += 1 }
                break
            }
            let node = pointer.pointee
            guard let path = String(validatingCString: node.fts_path) else {
                errors += 1
                if node.fts_info == FTS_D { fts_set(traversal, pointer, FTS_SKIP) }
                if !frames.isEmpty { frames[frames.count - 1].complete = false }
                continue
            }
            if node.fts_info == FTS_DP {
                if frames.last?.path == path { finish() }
                continue
            }
            if [FTS_ERR, FTS_NS, FTS_DNR, FTS_DC].contains(Int32(node.fts_info)) {
                if node.fts_level == 0 { throw failure(path, code: node.fts_errno) }
                errors += 1
                if !frames.isEmpty { frames[frames.count - 1].complete = false }
                if frames.last?.path == path { finish() }
                continue
            }
            guard let metadata = node.fts_statp?.pointee else { continue }
            let directory = node.fts_info == FTS_D
            if directory {
                directoryCount += 1
                if node.fts_level == 0 { rootDevice = metadata.st_dev }
                let suppressed = frames.last?.suppressesCandidates == true
                let url = URL(fileURLWithPath: path)
                let skipped = metadata.st_flags & datalessFlag != 0 || metadata.st_dev != rootDevice
                let reason =
                    node.fts_level > 0 && !suppressed && !skipped ? cleanupReason(url) : nil
                var folder = Folder(
                    path: path, metadata: metadata, reason: reason,
                    suppressesCandidates: suppressed || reason != nil
                        || url.lastPathComponent == ".Trash")
                if skipped {
                    if metadata.st_flags & datalessFlag != 0 { clouds += 1 } else { mounts += 1 }
                    folder.complete = false
                    folder.allocated = 0
                    folder.logical = 0
                    fts_set(traversal, pointer, FTS_SKIP)
                }
                frames.append(folder)
            } else {
                fileCount += 1
                let identity = FileIdentity(device: metadata.st_dev, inode: metadata.st_ino)
                let counted = metadata.st_nlink <= 1 || links.insert(identity).inserted
                let entry = BlitzTreeReport.Entry(
                    path: path, kind: "file_or_link",
                    allocatedBytes: counted ? allocated(metadata) : 0,
                    logicalBytes: counted ? UInt64(max(0, metadata.st_size)) : 0,
                    fileCount: 1, complete: true, reason: nil,
                    device: metadata.st_dev, inode: metadata.st_ino)
                if !frames.isEmpty {
                    frames[frames.count - 1].allocated += entry.allocatedBytes
                    frames[frames.count - 1].logical += entry.logicalBytes
                    frames[frames.count - 1].files += 1
                }
                if node.fts_level == 1 { children.insert(entry) }
                if entry.allocatedBytes >= minimumBytes { files.insert(entry) }
            }
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastProgress >= 0.15 {
                progress(fileCount + directoryCount)
                lastProgress = now
            }
        }
        while !frames.isEmpty { frames[frames.count - 1].complete = false; finish() }
        guard let total else { throw BlitzTreeError.failed("The folder could not be scanned.") }
        progress(fileCount + directoryCount)
        return BlitzTreeReport(
            root: root, scanSeconds: ProcessInfo.processInfo.systemUptime - started,
            summary: .init(
                allocatedBytes: total.allocated, logicalBytes: total.logical,
                fileCount: fileCount, directoryCount: directoryCount),
            coverage: .init(
                complete: total.complete && errors == 0 && clouds == 0 && mounts == 0,
                errors: errors, skippedCloudDirectories: clouds, skippedMountPoints: mounts),
            report: .init(
                candidates: candidates.entries, candidateCount: candidateCount,
                truncated: candidateCount > candidates.entries.count,
                inventory: .init(
                    largestChildren: children.entries, largestDirectories: directories.entries,
                    largestFiles: files.entries)))
    }

    static func resolvedDirectory(_ path: String) throws -> String {
        guard path.hasPrefix("/"), !path.contains("\0") else { throw BlitzTreeError.invalidRoot }
        var pending = path.split(separator: "/").map(String.init)
        var resolved = "/"
        var symlinks = 0
        while !pending.isEmpty {
            let component = pending.removeFirst()
            if component == "." { continue }
            if component == ".." {
                resolved = URL(fileURLWithPath: resolved).deletingLastPathComponent().path
                continue
            }
            let next = URL(fileURLWithPath: resolved).appendingPathComponent(component).path
            var metadata = stat()
            guard lstat(next, &metadata) == 0 else { throw failure(next) }
            guard metadata.st_flags & datalessFlag == 0 else {
                throw BlitzTreeError.failed(
                    "Cloud-only folder: \(next). Download it in Finder first.")
            }
            if metadata.st_mode & S_IFMT == S_IFLNK {
                symlinks += 1
                guard symlinks <= 40 else {
                    throw BlitzTreeError.failed("Too many symbolic links.")
                }
                let target = try FileManager.default.destinationOfSymbolicLink(atPath: next)
                if target.hasPrefix("/") { resolved = "/" }
                pending = target.split(separator: "/").map(String.init) + pending
            } else {
                guard metadata.st_mode & S_IFMT == S_IFDIR else { throw BlitzTreeError.invalidRoot }
                resolved = next
            }
        }
        guard let directory = opendir(resolved) else { throw failure(resolved) }
        closedir(directory)
        return resolved
    }

    private static let projectTargets = [
        "node_modules": "JavaScript dependencies, restored by install.",
        "__pycache__": "Compiled bytecode caches.",
        ".venv": "Recreated from requirements.",
        "venv": "Recreated from requirements.",
        "target": "Build output, rebuilt on next build.",
        ".gradle": "Rebuilt on next build.",
        "Pods": "Restored by pod install.",
        ".next": "Rebuilt on next build.",
        ".turbo": "Rebuilt on next build.",
    ]

    static func cleanupReason(_ url: URL) -> String? {
        let parent = url.deletingLastPathComponent()
        let name = url.lastPathComponent
        switch name {
        case "target"
        where !FileManager.default.fileExists(
            atPath: parent.appendingPathComponent("Cargo.toml").path):
            return nil
        case ".next"
        where !FileManager.default.fileExists(
            atPath: parent.appendingPathComponent("package.json").path):
            return nil
        case "venv"
        where !FileManager.default.fileExists(atPath: url.appendingPathComponent("pyvenv.cfg").path):
            return nil
        default: break
        }
        if let detail = projectTargets[name] { return detail }
        if name == "DerivedData", parent.lastPathComponent == "Xcode" {
            return "Xcode build intermediates."
        }
        if parent.lastPathComponent == "Caches",
            parent.deletingLastPathComponent().lastPathComponent == "Library"
        {
            return "Application cache. Quit the owning app before removing it."
        }
        if name == "_cacache", parent.lastPathComponent == ".npm" {
            return "Downloaded npm packages."
        }
        return nil
    }

    private static func allocated(_ metadata: stat) -> UInt64 {
        UInt64(max(0, metadata.st_blocks)) * 512
    }

    private static func failure(_ path: String, code: Int32 = errno) -> BlitzTreeError {
        .failed("Cannot read \(path): \(String(cString: strerror(code)))")
    }

    private struct FileIdentity: Hashable {
        let device: Int32
        let inode: UInt64
    }

    private struct Folder {
        let path: String
        let metadata: stat
        let reason: String?
        let suppressesCandidates: Bool
        var allocated: UInt64
        var logical: UInt64
        var files: UInt64 = 0
        var complete = true

        init(path: String, metadata: stat, reason: String?, suppressesCandidates: Bool) {
            self.path = path
            self.metadata = metadata
            self.reason = reason
            self.suppressesCandidates = suppressesCandidates
            allocated = BlitzTreeScanner.allocated(metadata)
            logical = UInt64(max(0, metadata.st_size))
        }

        var entry: BlitzTreeReport.Entry {
            .init(
                path: path, kind: "directory", allocatedBytes: allocated, logicalBytes: logical,
                fileCount: files, complete: complete, reason: reason,
                device: metadata.st_dev, inode: metadata.st_ino)
        }
    }

    private struct LargestEntries {
        let limit: Int
        var entries: [BlitzTreeReport.Entry] = []

        mutating func insert(_ entry: BlitzTreeReport.Entry) {
            guard limit > 0 else { return }
            func precedes(_ other: BlitzTreeReport.Entry) -> Bool {
                entry.allocatedBytes == other.allocatedBytes
                    ? entry.path < other.path : entry.allocatedBytes > other.allocatedBytes
            }
            if entries.count == limit, let last = entries.last, !precedes(last) { return }
            var low = 0
            var high = entries.count
            while low < high {
                let middle = (low + high) / 2
                if precedes(entries[middle]) { high = middle } else { low = middle + 1 }
            }
            entries.insert(entry, at: low)
            if entries.count > limit { entries.removeLast() }
        }
    }
}
