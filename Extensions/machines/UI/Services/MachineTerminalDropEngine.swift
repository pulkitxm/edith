import Foundation

@MainActor final class MachineTerminalDropEngine {
    private struct Upload {
        let terminal: UUID
        let directory: URL
        let file: URL
        let writer: FileHandle
        let count: UInt64
        var offset: UInt64 = 0
        var touched = ContinuousClock.now
    }
    private var uploads: [UUID: Upload] = [:]
    private var directories: [UUID: Set<URL>] = [:]
    private let root: URL
    init(root: URL = MachinePaths.root.appendingPathComponent("terminal-drops")) {
        self.root = root
    }

    func execute(_ request: MachineTerminalRequest, session: MachineSession) async throws
        -> MachineTerminalFrame
    {
        guard let terminal = request.handle else { throw MachineUIError.invalidRequest }
        switch request.operation {
        case .dropBegin:
            guard uploads.count < 8, request.dropCount > 0, request.dropCount <= 536_870_912,
                !request.fileExtension.isEmpty, request.fileExtension.utf8.count <= 16,
                request.fileExtension.utf8.allSatisfy({
                    (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                })
            else { throw MachineUIError.invalidRequest }
            let directory = try ownedDirectory(terminal)
            let file = directory.appendingPathComponent("drop." + request.fileExtension)
            do {
                guard
                    FileManager.default.createFile(
                        atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
                else { throw CocoaError(.fileWriteUnknown) }
                let id = UUID()
                uploads[id] = Upload(
                    terminal: terminal, directory: directory, file: file,
                    writer: try FileHandle(forWritingTo: file), count: request.dropCount)
                return MachineTerminalFrame(handle: terminal, dropID: id)
            } catch { remove(directory, terminal: terminal); throw error }
        case .dropWrite:
            guard let id = request.dropID, var upload = uploads[id], upload.terminal == terminal,
                upload.offset == request.offset, !request.bytes.isEmpty,
                UInt64(request.bytes.count) <= upload.count - upload.offset
            else { throw MachineUIError.invalidRequest }
            try upload.writer.write(contentsOf: request.bytes)
            upload.offset += UInt64(request.bytes.count); upload.touched = .now;
            uploads[id] = upload
            return MachineTerminalFrame(handle: terminal, nextOffset: upload.offset, dropID: id)
        case .dropFinish, .dropCancel:
            guard let id = request.dropID, let upload = uploads[id], upload.terminal == terminal
            else { throw MachineUIError.invalidRequest }
            if request.operation == .dropFinish {
                guard upload.offset == upload.count else { throw MachineUIError.invalidRequest }
            }
            uploads.removeValue(forKey: id)
            try upload.writer.close()
            if request.operation == .dropCancel {
                remove(upload.directory, terminal: terminal);
                return MachineTerminalFrame(handle: terminal)
            }
            do {
                let paths = try await deliver([upload.file], session: session)
                try Task.checkCancellation()
                guard directories[terminal]?.contains(upload.directory) == true else {
                    throw MachineUIError.unavailable
                }
                if !session.isLocal { remove(upload.directory, terminal: terminal) }
                return MachineTerminalFrame(handle: terminal, paths: paths)
            } catch { remove(upload.directory, terminal: terminal); throw error }
        case .dropPaths:
            guard !request.paths.isEmpty,
                Set(request.temporaryPaths).isSubset(of: Set(request.paths))
            else { throw MachineUIError.invalidRequest }
            var sources: [URL] = [], imported: [URL] = []
            do {
                for path in request.paths {
                    try Task.checkCancellation()
                    let source = URL(fileURLWithPath: path)
                    if !session.isLocal || !request.temporaryPaths.contains(path) {
                        sources.append(source); continue
                    }
                    let directory = try ownedDirectory(terminal); imported.append(directory)
                    let target = directory.appendingPathComponent(source.lastPathComponent)
                    let task = Task.detached { try Self.copy(source, to: target) }
                    try await withTaskCancellationHandler {
                        try await task.value
                    } onCancel: {
                        task.cancel()
                    }
                    try Task.checkCancellation()
                    guard directories[terminal]?.contains(directory) == true else {
                        throw MachineUIError.unavailable
                    }
                    sources.append(target)
                }
                let paths = try await deliver(sources, session: session)
                try Task.checkCancellation()
                return MachineTerminalFrame(handle: terminal, paths: paths)
            } catch {
                for directory in imported { remove(directory, terminal: terminal) }; throw error
            }
        default: throw MachineUIError.invalidRequest
        }
    }

    private func deliver(_ urls: [URL], session: MachineSession) async throws -> [String] {
        if session.isLocal { return urls.map(\.path) }
        guard let connection = session.connectionRef else { throw MachineUIError.unavailable }
        return try await TerminalDropTransfer.upload(urls, over: connection)
    }

    func close(_ terminal: UUID) {
        for (id, upload) in uploads where upload.terminal == terminal {
            try? upload.writer.close(); uploads.removeValue(forKey: id)
        }
        for directory in directories.removeValue(forKey: terminal) ?? [] {
            try? FileManager.default.removeItem(at: directory)
        }
    }
    func shutdown() { for terminal in Array(directories.keys) { close(terminal) } }
    func expire() {
        for (id, upload) in uploads where upload.touched.duration(to: .now) > .seconds(10) {
            try? upload.writer.close(); uploads.removeValue(forKey: id);
            remove(upload.directory, terminal: upload.terminal)
        }
    }
    private func ownedDirectory(_ terminal: UUID) throws -> URL {
        guard directories.values.reduce(0, { $0 + $1.count }) < 128 else {
            throw MachineUIError.unavailable
        }
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        directories[terminal, default: []].insert(directory); return directory
    }
    private func remove(_ directory: URL, terminal: UUID) {
        directories[terminal]?.remove(directory); try? FileManager.default.removeItem(at: directory)
    }
    nonisolated private static func copy(_ source: URL, to target: URL) throws {
        var bytes: UInt64 = 0
        var entries = 0
        func visit(_ source: URL, _ target: URL, depth: Int) throws {
            try Task.checkCancellation()
            entries += 1
            guard entries <= 1_024, depth <= 32 else { throw CocoaError(.fileWriteOutOfSpace) }
            let values = try source.resourceValues(forKeys: [
                .isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey,
            ])
            if values.isSymbolicLink == true {
                try FileManager.default.copyItem(at: source, to: target)
            } else if values.isDirectory == true {
                try FileManager.default.createDirectory(
                    at: target, withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700])
                for child in try FileManager.default.contentsOfDirectory(
                    at: source, includingPropertiesForKeys: nil)
                {
                    try visit(
                        child, target.appendingPathComponent(child.lastPathComponent),
                        depth: depth + 1)
                }
            } else {
                guard values.isRegularFile == true,
                    FileManager.default.createFile(
                        atPath: target.path, contents: nil, attributes: [.posixPermissions: 0o600])
                else { throw CocoaError(.fileReadUnsupportedScheme) }
                let reader = try FileHandle(forReadingFrom: source)
                let writer = try FileHandle(forWritingTo: target)
                defer { try? reader.close(); try? writer.close() }
                while let chunk = try reader.read(upToCount: 65_536), !chunk.isEmpty {
                    try Task.checkCancellation()
                    bytes += UInt64(chunk.count)
                    guard bytes <= 536_870_912 else { throw CocoaError(.fileWriteOutOfSpace) }
                    try writer.write(contentsOf: chunk)
                }
            }
        }
        try visit(source, target, depth: 0)
    }
}
