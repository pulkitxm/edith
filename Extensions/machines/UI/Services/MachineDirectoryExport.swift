import Foundation

@MainActor final class MachineDirectoryExport {
    private struct Export {
        var machineID: UUID
        var root: URL
        var handle: MachineDirectoryExportHandle
        var file: FileHandle?
        var path = ""
        var offset: UInt64 = 0
        var touched: Date
        var completed: Set<String> = []
    }
    private var exports: [UUID: Export] = [:]
    private let session: (UUID) throws -> MachineSession
    private var reaper: Task<Void, Never>?
    private var stopped = false
    private var preparing = 0

    init(session: @escaping (UUID) throws -> MachineSession) { self.session = session }

    func execute(_ request: MachineDirectoryExportRequest) async throws -> Data {
        guard !stopped, request.maximumBytes > 0,
            request.maximumBytes <= RemoteFileOperationExecution.cacheLimitBytes
        else { throw MachineUIError.invalidRequest }
        switch request.operation {
        case .prepare:
            guard exports.count + preparing < 8, let entry = request.entry, entry.isDirectory,
                MachineDirectoryExportRequest.validPath(entry.name), !entry.name.contains("/"),
                entry.path.utf8.count <= 4096,
                !entry.path.utf8.contains(0)
            else { throw MachineUIError.invalidRequest }
            preparing += 1
            defer { preparing -= 1 }
            let session = try session(request.machineID)
            let root = MachinePaths.previewCacheDir.appendingPathComponent("directory-exports")
                .appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            var items: [MachineDirectoryExportItem] = []
            var total: UInt64 = 0
            var pathBytes = 0
            do {
                func collect(_ entry: RemoteFileEntry, relative: String) async throws {
                    try Task.checkCancellation()
                    guard !stopped, MachineDirectoryExportRequest.validPath(relative),
                        items.count < 8192,
                        pathBytes + relative.utf8.count <= 2097152
                    else { throw MachineUIError.invalidRequest }
                    pathBytes += relative.utf8.count
                    let destination = root.appendingPathComponent(relative)
                    switch entry.kind {
                    case .directory:
                        try FileManager.default.createDirectory(
                            at: destination, withIntermediateDirectories: false)
                        items.append(
                            .init(
                                path: relative, kind: .directory, count: 0, modified: entry.modified
                            ))
                        let children = try await session.listFiles(path: entry.path).get()
                        guard children.count <= 8192 else { throw MachineUIError.invalidRequest }
                        for child in children {
                            guard MachineDirectoryExportRequest.validPath(child.name),
                                !child.name.contains("/"),
                                child.path == FileListing.join(parent: entry.path, name: child.name)
                            else { throw MachineUIError.invalidRequest }
                            try await collect(child, relative: relative + "/" + child.name)
                        }
                    case .file:
                        guard entry.sizeBytes >= 0,
                            UInt64(entry.sizeBytes) <= UInt64(request.maximumBytes) - total
                        else {
                            throw RemoteFileOperationError.cacheBudgetExceeded(request.maximumBytes)
                        }
                        if session.isLocal {
                            try await LocalFileCopy.copy(
                                URL(fileURLWithPath: entry.path), to: destination)
                        } else {
                            guard let connection = session.connectionRef else {
                                throw FinderTransferError.notConnected
                            }
                            try await connection.download(
                                remotePath: entry.path, to: destination,
                                maximumBytes: Int64(UInt64(request.maximumBytes) - total))
                        }
                        let count = UInt64(
                            try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
                        guard count <= UInt64(request.maximumBytes) - total else {
                            throw RemoteFileOperationError.cacheBudgetExceeded(request.maximumBytes)
                        }
                        total += count
                        items.append(
                            .init(
                                path: relative, kind: .file, count: count, modified: entry.modified)
                        )
                    case .symlink:
                        guard let target = entry.linkTarget, target.utf8.count <= 4096,
                            !target.utf8.contains(0)
                        else { throw MachineUIError.invalidRequest }
                        items.append(
                            .init(
                                path: relative, kind: .symlink, count: 0, linkTarget: target,
                                modified: entry.modified))
                    case .other:
                        throw MachineUIFailure(
                            message: "This item cannot be exported: \(entry.name)")
                    }
                }
                try await collect(entry, relative: entry.name)
                try Task.checkCancellation()
                guard !stopped else { throw MachineUIError.unavailable }
                let id = UUID()
                let handle = MachineDirectoryExportHandle(
                    id: id, name: entry.name, items: items, count: total)
                exports[id] = Export(
                    machineID: session.id, root: root, handle: handle, touched: Date())
                startReaper()
                return try JSONEncoder().encode(handle)
            } catch { try? FileManager.default.removeItem(at: root); throw error }
        case .read:
            guard let id = request.id, var export = exports[id],
                export.machineID == request.machineID,
                MachineDirectoryExportRequest.validPath(request.path),
                let item = export.handle.items.first(where: {
                    $0.path == request.path && $0.kind == .file
                }),
                !export.completed.contains(request.path)
            else { throw MachineUIError.invalidRequest }
            if export.file == nil {
                guard request.offset == 0 else { throw MachineUIError.stale }
                export.file = try FileHandle(
                    forReadingFrom: export.root.appendingPathComponent(item.path))
                export.path = item.path; export.offset = 0
            }
            guard export.path == request.path, export.offset == request.offset else {
                throw MachineUIError.stale
            }
            let bytes = try export.file?.read(upToCount: 65536) ?? Data()
            guard UInt64(bytes.count) <= item.count - export.offset,
                !bytes.isEmpty || export.offset == item.count
            else { throw MachineUIError.stale }
            export.offset += UInt64(bytes.count)
            export.touched = Date()
            let complete = export.offset == item.count
            if complete {
                try export.file?.close(); export.file = nil; export.completed.insert(item.path)
            }
            exports[id] = export
            return try JSONEncoder().encode(
                MachinePreviewChunk(offset: request.offset, bytes: bytes, complete: complete))
        case .close:
            guard let id = request.id else { throw MachineUIError.invalidRequest }
            if let export = exports[id] {
                guard export.machineID == request.machineID else {
                    throw MachineUIError.invalidRequest
                }
                close(id)
            }
            return try JSONEncoder().encode(true)
        }
    }

    private func startReaper() {
        guard reaper == nil else { return }
        reaper = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                guard let self, !stopped else { return }
                for id in exports.keys.filter({
                    Date().timeIntervalSince(self.exports[$0]!.touched) > 10
                }) { close(id) }
            }
        }
    }

    private func close(_ id: UUID) {
        guard let export = exports.removeValue(forKey: id) else { return }
        try? export.file?.close()
        try? FileManager.default.removeItem(at: export.root)
    }

    func shutdown() {
        stopped = true
        reaper?.cancel(); reaper = nil
        for id in Array(exports.keys) { close(id) }
    }
}
