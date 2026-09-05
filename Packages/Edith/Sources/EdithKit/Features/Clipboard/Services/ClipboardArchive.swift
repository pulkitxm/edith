import Darwin
import Foundation

public final class ClipboardArchive: @unchecked Sendable {
    public static let maximumBlobBytes = 16 << 20
    public static let maximumIndexBytes = 8 << 20
    public static let maximumEntries = 4096
    public let root: URL
    private let writeBlob: @Sendable (Data, URL) throws -> Void
    private var cachedIndex: CachedIndex?
    private var index: URL { root.appendingPathComponent("index.jsonl") }
    private var blobs: URL { root.appendingPathComponent("blobs") }

    private struct FileVersion: Equatable {
        let device: Int32
        let inode: UInt64
        let size: Int64
        let modified: Int
        let modifiedNanoseconds: Int
        let changed: Int
        let changedNanoseconds: Int

        init(_ value: stat) {
            device = value.st_dev
            inode = value.st_ino
            size = value.st_size
            modified = value.st_mtimespec.tv_sec
            modifiedNanoseconds = value.st_mtimespec.tv_nsec
            changed = value.st_ctimespec.tv_sec
            changedNanoseconds = value.st_ctimespec.tv_nsec
        }
    }

    private struct CachedIndex {
        let version: FileVersion
        let entries: [ClipboardEntry]
        let arranged: [ClipboardEntry]
        let recentlyCreated: [ClipboardEntry]
        let revision: String
    }

    public init(
        root: URL = ClipboardPaths.dir,
        writeBlob: @escaping @Sendable (Data, URL) throws -> Void = {
            try UsageDataFiles.write($0, to: $1)
        }
    ) {
        self.root = root
        self.writeBlob = writeBlob
    }

    public func capture(
        _ capture: ClipboardCapture, maxItems: Int, maxBytes: Int, maxAge: TimeInterval?
    ) throws -> ClipboardMutationResult {
        guard UUID(uuidString: capture.id) != nil,
            capture.data.count <= min(max(0, maxBytes), Self.maximumBlobBytes),
            validExtension(capture.ext), capture.types.count <= 32,
            capture.types.allSatisfy({ $0.utf8.count <= 256 }),
            capture.preview.count <= 500,
            (capture.sourceApp?.utf8.count ?? 0) <= 256,
            (capture.sourceBundleID?.utf8.count ?? 0) <= 256,
            capture.capturedAt.timeIntervalSince1970.isFinite,
            capture.capturedAt <= Date().addingTimeInterval(60)
        else { throw AgentError(.refused, "The clipboard capture exceeds the supported limits.") }
        try Task.checkCancellation()
        let sha = ClipboardRepository.sha256Hex(capture.data)
        return try withLock {
            var entries = try load()
            let existing = entries.first { $0.sha256 == sha && $0.ext == capture.ext }
            if let existing,
                existing.lastCopiedAt.timeIntervalSince1970
                    >= floor(capture.capturedAt.timeIntervalSince1970)
            {
                return ClipboardMutationResult(changed: 0, total: entries.count)
            }
            let previous = entries
            let entry = ClipboardEntry(
                id: existing?.id ?? capture.id, sha256: sha, types: capture.types,
                ext: capture.ext, sourceApp: capture.sourceApp,
                sourceBundleID: capture.sourceBundleID,
                createdAt: existing?.createdAt ?? capture.capturedAt,
                lastCopiedAt: capture.capturedAt, size: capture.data.count,
                preview: capture.preview, pinned: existing?.pinned ?? false)
            entries.removeAll { $0.sha256 == sha && $0.ext == capture.ext }
            entries.append(entry)
            entries = ClipboardIndex.applyRetention(
                entries, maxItems: max(0, min(Self.maximumEntries, maxItems)), maxAge: maxAge)
            guard entries.count <= Self.maximumEntries else {
                throw AgentError(.refused, "Clipboard history has reached its pinned item limit.")
            }
            try ensureDirectory(blobs)
            let destination = try blobURL(entry)
            let stored = try read(destination, maximum: Self.maximumBlobBytes)
            if let stored, stored != capture.data {
                throw AgentError(.failed, "The stored clipboard payload failed verification.")
            }
            if stored == nil { try writeBlob(capture.data, destination) }
            do {
                try Task.checkCancellation()
                try save(entries)
            } catch {
                if stored == nil { try? FileManager.default.removeItem(at: destination) }
                throw error
            }
            pruneRemoved(previous + [entry], keeping: entries)
            return ClipboardMutationResult(changed: 1, total: entries.count)
        }
    }

    public func mutate(_ mutation: ClipboardMutation) throws -> ClipboardMutationResult {
        guard mutation.ids.count <= Self.maximumEntries,
            mutation.ids.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 128 }),
            mutation.copiedAt.timeIntervalSince1970.isFinite,
            mutation.copiedAt <= Date().addingTimeInterval(60)
        else { throw AgentError(.refused, "The clipboard mutation is invalid.") }
        return try withLock {
            var entries = try load()
            let previous = entries
            let ids = Set(mutation.ids)
            var changed = 0
            for index in entries.indices where ids.contains(entries[index].id) {
                switch mutation.kind {
                case .pin, .unpin:
                    let pinned = mutation.kind == .pin
                    if entries[index].pinned != pinned {
                        entries[index].pinned = pinned
                        changed += 1
                    }
                case .copied:
                    if entries[index].lastCopiedAt < mutation.copiedAt {
                        entries[index].lastCopiedAt = mutation.copiedAt
                        changed += 1
                    }
                case .delete: changed += 1
                }
            }
            if mutation.kind == .delete { entries.removeAll { ids.contains($0.id) } }
            if changed > 0 {
                try Task.checkCancellation()
                try save(entries)
                pruneRemoved(previous, keeping: entries)
            }
            return ClipboardMutationResult(changed: changed, total: entries.count)
        }
    }

    public func snapshot(_ request: ClipboardSnapshotRequest) throws -> ClipboardSnapshot {
        guard request.offset >= 0, request.offset <= Self.maximumEntries,
            request.limit > 0, request.limit <= 512
        else { throw AgentError(.refused, "The clipboard page is outside the supported limits.") }
        return try withLock {
            let entries = try load()
            let revision = cachedIndex?.revision ?? ClipboardRepository.sha256Hex(Data())
            if let expected = request.revision, expected != revision {
                throw AgentError(.unavailable, AgentClipboardOperation.changedDuringRead)
            }
            let ordered =
                request.recentlyCreated
                ? cachedIndex?.recentlyCreated ?? [] : cachedIndex?.arranged ?? []
            return ClipboardSnapshot(
                entries: Array(ordered.dropFirst(request.offset).prefix(request.limit)),
                revision: revision, total: entries.count)
        }
    }

    public func entry(id: String) throws -> ClipboardEntry {
        guard id.utf8.count <= 128 else {
            throw AgentError(.refused, "The clipboard identifier is invalid.")
        }
        return try withLock {
            guard let entry = try load().first(where: { $0.id == id }) else {
                throw AgentError(.unavailable, "The clipboard entry is missing.")
            }
            return entry
        }
    }

    public func payload(id: String) throws -> ClipboardStoredPayload {
        guard id.utf8.count <= 128 else {
            throw AgentError(.refused, "The clipboard identifier is invalid.")
        }
        return try withLock {
            guard let entry = try load().first(where: { $0.id == id }),
                let data = try read(blobURL(entry), maximum: Self.maximumBlobBytes)
            else { throw AgentError(.unavailable, "The stored clipboard payload is missing.") }
            guard data.count == entry.size, ClipboardRepository.sha256Hex(data) == entry.sha256
            else {
                throw AgentError(.failed, "The stored clipboard payload failed verification.")
            }
            return ClipboardStoredPayload(entry: entry, data: data)
        }
    }

    public func stats() throws -> ClipboardActions.Stats {
        try withLock {
            let entries = try load()
            var diskBytes = 0
            try ensureDirectory(blobs)
            let files = try FileManager.default.contentsOfDirectory(
                at: blobs,
                includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard files.count <= Self.maximumEntries * 2 else {
                throw AgentError(.refused, "Clipboard storage contains too many files to inspect.")
            }
            for file in files {
                let values = try file.resourceValues(forKeys: [
                    .fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey,
                ])
                if values.isRegularFile == true, values.isSymbolicLink != true {
                    diskBytes += values.fileSize ?? 0
                }
            }
            let kinds = ClipboardEntry.Kind.allCases.compactMap {
                kind -> ClipboardActions.KindTotal? in
                let matching = entries.filter { $0.kind == kind }
                guard !matching.isEmpty else { return nil }
                return ClipboardActions.KindTotal(
                    kind: kind, count: matching.count, bytes: matching.reduce(0) { $0 + $1.size })
            }
            return ClipboardActions.Stats(
                count: entries.count, pinned: entries.filter(\.pinned).count,
                bytes: entries.reduce(0) { $0 + $1.size }, diskBytes: diskBytes,
                largest: entries.map(\.size).max() ?? 0, oldest: entries.map(\.createdAt).min(),
                newest: entries.map(\.lastCopiedAt).max(), byKind: kinds)
        }
    }

    public func mergeAvailableCloudEntries(from source: URL) throws {
        guard let data = try read(source, maximum: Self.maximumIndexBytes) else { return }
        let imported = try decode(data)
        try withLock {
            var entries = try load()
            var ids = Set(entries.map(\.id))
            var hashes = Set(entries.map { $0.sha256 + "." + $0.ext })
            for entry in imported
            where !ids.contains(entry.id) && !hashes.contains(entry.sha256 + "." + entry.ext) {
                guard let blob = try read(blobURL(entry), maximum: Self.maximumBlobBytes),
                    blob.count == entry.size, ClipboardRepository.sha256Hex(blob) == entry.sha256
                else { continue }
                entries.append(entry)
                ids.insert(entry.id)
                hashes.insert(entry.sha256 + "." + entry.ext)
            }
            guard entries.count <= Self.maximumEntries else {
                throw AgentError(.refused, "The cloud clipboard exceeds the history limit.")
            }
            try save(entries)
        }
    }

    public func restoreBlob(from source: URL, name: String) throws {
        let parts = name.split(separator: ".", maxSplits: 1).map(String.init)
        guard parts.count == 2, validHash(parts[0]), validExtension(parts[1]),
            let data = try read(source, maximum: Self.maximumBlobBytes),
            ClipboardRepository.sha256Hex(data) == parts[0]
        else { throw AgentError(.refused, "The cloud clipboard payload is invalid.") }
        try withLock {
            try ensureDirectory(blobs)
            let destination = blobs.appendingPathComponent(name)
            if try read(destination, maximum: Self.maximumBlobBytes) == nil {
                try writeBlob(data, destination)
            }
        }
    }

    public func stageExport(to destination: URL) throws {
        try withLock {
            let entries = try load()
            let supported: Set<String> = ["txt", "rtf", "html", "url", "png", "tiff"]
            let output = destination.appendingPathComponent("blobs")
            try ensureDirectory(output)
            var exported: [ClipboardEntry] = []
            for entry in entries where supported.contains(entry.ext) && entry.size <= 1_048_576 {
                try Task.checkCancellation()
                guard let data = try read(blobURL(entry), maximum: 1_048_576),
                    data.count == entry.size, ClipboardRepository.sha256Hex(data) == entry.sha256
                else { continue }
                try data.write(to: output.appendingPathComponent(entry.sha256 + "." + entry.ext))
                exported.append(entry)
            }
            try Task.checkCancellation()
            try Data(ClipboardIndex.encode(exported).utf8).write(
                to: destination.appendingPathComponent("index.jsonl"), options: .atomic)
        }
    }

    private func withLock<Value>(_ body: () throws -> Value) throws -> Value {
        try ensureDirectory(root)
        let descriptor = open(
            root.appendingPathComponent(".lock").path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC,
            0o600)
        guard descriptor >= 0 else {
            throw AgentError(.unavailable, "The clipboard archive lock is unavailable.")
        }
        defer { close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG else {
            throw AgentError(.refused, "The clipboard archive lock is invalid.")
        }
        let deadline = Date().addingTimeInterval(5)
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            try Task.checkCancellation()
            guard errno == EWOULDBLOCK, Date() < deadline else {
                throw AgentError(.unavailable, "The clipboard archive is busy.")
            }
            usleep(1000)
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        try Task.checkCancellation()
        return try body()
    }

    private func load() throws -> [ClipboardEntry] {
        var metadata = stat()
        if lstat(index.path, &metadata) != 0 {
            guard errno == ENOENT else {
                throw AgentError(.failed, "The clipboard index cannot be inspected.")
            }
            cachedIndex = nil
            return []
        }
        guard metadata.st_mode & S_IFMT == S_IFREG,
            metadata.st_size <= Self.maximumIndexBytes
        else { throw AgentError(.refused, "The clipboard index is invalid.") }
        let version = FileVersion(metadata)
        if let cachedIndex, cachedIndex.version == version { return cachedIndex.entries }
        guard let data = try read(index, maximum: Self.maximumIndexBytes) else { return [] }
        let entries = try decode(data)
        cachedIndex = CachedIndex(
            version: version, entries: entries, arranged: ClipboardActions.arrange(entries),
            recentlyCreated: entries.sorted {
                $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt > $1.createdAt
            }, revision: ClipboardRepository.sha256Hex(data))
        return entries
    }

    private func decode(_ data: Data) throws -> [ClipboardEntry] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let lines = data.split(separator: 10)
        guard lines.count <= Self.maximumEntries else {
            throw AgentError(.refused, "Clipboard history exceeds the supported item limit.")
        }
        var ids = Set<String>()
        return try lines.map { line in
            let entry = try decoder.decode(ClipboardEntry.self, from: Data(line))
            guard !entry.id.isEmpty, entry.id.utf8.count <= 128, ids.insert(entry.id).inserted,
                validHash(entry.sha256), validExtension(entry.ext), entry.size >= 0,
                entry.size <= Self.maximumBlobBytes, entry.types.count <= 32,
                entry.types.allSatisfy({ $0.utf8.count <= 256 }),
                (entry.sourceApp?.utf8.count ?? 0) <= 256,
                (entry.sourceBundleID?.utf8.count ?? 0) <= 256
            else { throw AgentError(.failed, "A clipboard history entry is invalid.") }
            return entry
        }
    }

    private func save(_ entries: [ClipboardEntry]) throws {
        let data = Data(ClipboardIndex.encode(entries).utf8)
        guard data.count <= Self.maximumIndexBytes else {
            throw AgentError(.refused, "The clipboard index exceeds the supported size.")
        }
        try UsageDataFiles.write(data, to: index)
        cachedIndex = nil
    }

    private func pruneRemoved(_ previous: [ClipboardEntry], keeping entries: [ClipboardEntry]) {
        let retained = Set(entries.map { $0.sha256 + "." + $0.ext })
        for entry in previous where !retained.contains(entry.sha256 + "." + entry.ext) {
            if let url = try? blobURL(entry) { try? FileManager.default.removeItem(at: url) }
        }
    }

    private func blobURL(_ entry: ClipboardEntry) throws -> URL {
        guard validHash(entry.sha256), validExtension(entry.ext) else {
            throw AgentError(.refused, "The clipboard payload path is invalid.")
        }
        var metadata = stat()
        if lstat(blobs.path, &metadata) == 0, metadata.st_mode & S_IFMT != S_IFDIR {
            throw AgentError(.refused, "The clipboard payload directory is invalid.")
        }
        return blobs.appendingPathComponent(entry.sha256 + "." + entry.ext)
    }

    private func validHash(_ value: String) -> Bool {
        value.utf8.count == 64
            && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private func validExtension(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 32
            && value.utf8.allSatisfy {
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
            }
    }

    private func ensureDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw AgentError(.refused, "The clipboard storage directory is invalid.")
        }
    }

    private func read(_ url: URL, maximum: Int) throws -> Data? {
        try UsageDataFiles.readRegularFile(at: url, maximumBytes: maximum)
    }
}
