import AppKit
import EdithExtensionSupport
import Foundation
import GhosttyTerminal

@MainActor final class TerminalEngineFiles {
    struct SessionEnvelope: Codable { let session: TerminalEngine.SessionRequest }
    struct Begin: Codable { let session: TerminalEngine.SessionRequest; let fileExtension: String }
    struct Handle: Codable { let session: TerminalEngine.SessionRequest; let token: UUID }
    struct Chunk: Codable { let handle: Handle; let offset: UInt64; let bytes: Data }
    struct Paths: Codable {
        struct Item: Codable { let path: String; let temporary: Bool }
        let session: TerminalEngine.SessionRequest
        let items: [Item]
    }
    struct Link: Codable {
        let session: TerminalEngine.SessionRequest; let value: String; let untrusted: Bool
    }
    struct LinkReply: Codable { let token: UUID?; let resolution: TerminalLinkResolution }
    struct Receipt: Codable { let offset: UInt64 }
    private struct Upload {
        let handle: Handle; let directory: URL; let file: URL; let writer: FileHandle;
        var offset: UInt64; var expires: Date
    }
    private struct Target { let handle: Handle; let url: URL; let expires: Date }
    static let commands: Set<String> = [
        "terminal.drop.begin", "terminal.drop.write", "terminal.drop.finish",
        "terminal.drop.cancel", "terminal.drop.paths", "terminal.resolveLink", "terminal.openLink",
    ]
    nonisolated static let maximumBytes: UInt64 = 536_870_912
    private var uploads: [UUID: Upload] = [:]
    private var targets: [UUID: Target] = [:]
    private var directories: [UUID: Set<URL>] = [:]
    private let open: @MainActor (URL) -> Bool
    private let handler: @MainActor (URL) -> String
    private let root: URL
    private let copy: @Sendable (URL, URL) async throws -> Void
    private var stopped = false
    private var imports: [UUID: (session: UUID, task: Task<Void, Error>)] = [:]
    private var cleanups: [UUID: Task<Void, Never>] = [:]

    init(
        root: URL = FileManager.default.temporaryDirectory,
        open: @escaping @MainActor (URL) -> Bool = { NSWorkspace.shared.open($0) },
        handler: @escaping @MainActor (URL) -> String = {
            NSWorkspace.shared.urlForApplication(toOpen: $0)?.deletingPathExtension()
                .lastPathComponent ?? "the default application"
        },
        copy: @escaping @Sendable (URL, URL) async throws -> Void = {
            try TerminalEngineFiles.copy($0, to: $1)
        }
    ) {
        self.root = root; self.open = open; self.handler = handler; self.copy = copy
    }

    func execute(
        _ command: String, payload: Data, session: TerminalEngine.SessionRequest, directory: String,
        input: @escaping @MainActor (Data) throws -> Void
    ) async throws -> Data {
        guard !stopped else { throw ExtensionPeerError.unavailable }
        expire()
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        switch command {
        case "terminal.drop.begin":
            let request = try decoder.decode(Begin.self, from: payload)
            guard uploads.count < 8, !request.fileExtension.isEmpty,
                request.fileExtension.utf8.count <= 16,
                request.fileExtension.utf8.allSatisfy({
                    (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                })
            else { throw ExtensionPeerError.invalidRequest }
            let handle = Handle(session: session, token: UUID())
            let directory = try ownedDirectory(session.id)
            let file = directory.appendingPathComponent("drop." + request.fileExtension)
            do {
                guard
                    FileManager.default.createFile(
                        atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
                else { throw CocoaError(.fileWriteUnknown) }
                uploads[handle.token] = Upload(
                    handle: handle, directory: directory, file: file,
                    writer: try FileHandle(forWritingTo: file), offset: 0,
                    expires: Date().addingTimeInterval(60))
            } catch { remove(directory, session: session.id); throw error }
            return try encoder.encode(handle)
        case "terminal.drop.write":
            let request = try decoder.decode(Chunk.self, from: payload)
            guard var upload = uploads[request.handle.token], matches(upload.handle, session),
                !request.bytes.isEmpty, request.bytes.count <= 16_384,
                upload.offset == request.offset,
                upload.offset + UInt64(request.bytes.count) <= Self.maximumBytes
            else { throw ExtensionPeerError.invalidRequest }
            try upload.writer.write(contentsOf: request.bytes)
            upload.offset += UInt64(request.bytes.count)
            upload.expires = Date().addingTimeInterval(60)
            uploads[request.handle.token] = upload
            return try encoder.encode(Receipt(offset: upload.offset))
        case "terminal.drop.finish", "terminal.drop.cancel":
            let request = try decoder.decode(Handle.self, from: payload)
            guard let upload = uploads[request.token], matches(upload.handle, session) else {
                throw ExtensionPeerError.invalidRequest
            }
            uploads[request.token] = nil
            try upload.writer.close()
            if command == "terminal.drop.cancel" {
                remove(upload.directory, session: session.id)
            } else {
                guard upload.offset > 0 else {
                    remove(upload.directory, session: session.id);
                    throw ExtensionPeerError.invalidRequest
                }
                do { try input(Data(GhosttyTerminalView.quotePath(upload.file.path).utf8)) } catch {
                    remove(upload.directory, session: session.id); throw error
                }
            }
        case "terminal.drop.paths":
            let request = try decoder.decode(Paths.self, from: payload)
            guard !request.items.isEmpty, request.items.count <= 32,
                request.items.allSatisfy({
                    $0.path.hasPrefix("/") && $0.path.utf8.count <= 4_096
                        && !$0.path.utf8.contains(0)
                })
            else { throw ExtensionPeerError.invalidRequest }
            let id = UUID()
            let task = Task {
                try await importPaths(request, session: session, input: input)
            }
            imports[id] = (session.id, task)
            defer { imports[id] = nil }
            try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
        case "terminal.resolveLink":
            let request = try decoder.decode(Link.self, from: payload)
            guard request.value.utf8.count <= 4_096, !request.value.utf8.contains(0),
                targets.count < 32
            else { throw ExtensionPeerError.invalidRequest }
            let resolution = TerminalLinkResolution.resolve(
                request.value, directory: directory, untrusted: request.untrusted, handler: handler)
            var token: UUID?
            if resolution.disposition != .deny, let url = URL(string: resolution.target) {
                let handle = Handle(session: session, token: UUID())
                targets[handle.token] = Target(
                    handle: handle, url: url, expires: Date().addingTimeInterval(60))
                token = handle.token
            }
            return try encoder.encode(LinkReply(token: token, resolution: resolution))
        case "terminal.openLink":
            let request = try decoder.decode(Handle.self, from: payload)
            guard let target = targets[request.token], matches(target.handle, session),
                target.expires > Date()
            else { throw ExtensionPeerError.invalidRequest }
            targets[request.token] = nil
            guard open(target.url) else { throw ExtensionPeerError.unavailable }
        default: throw ExtensionPeerError.invalidRequest
        }
        return Data("{}".utf8)
    }

    func close(_ id: UUID) {
        let writers = uploads.filter { $0.value.handle.session.id == id }
        for token in writers.keys { uploads[token] = nil }
        targets = targets.filter { $0.value.handle.session.id != id }
        let directories = directories.removeValue(forKey: id) ?? []
        let pending = imports.values.filter { $0.session == id }.map(\.task)
        for upload in writers.values { try? upload.writer.close() }
        if pending.isEmpty {
            for directory in directories { try? FileManager.default.removeItem(at: directory) }
            return
        }
        for task in pending { task.cancel() }
        let token = UUID()
        cleanups[token] = Task { [self] in
            defer { cleanups[token] = nil }
            for task in pending { _ = await task.result }
            for directory in directories { try? FileManager.default.removeItem(at: directory) }
        }
    }

    func beginSuspension() {
        stopped = true
        for operation in imports.values { operation.task.cancel() }
    }

    func stop() {
        beginSuspension()
        for id in Array(directories.keys) { close(id) }
        targets.removeAll()
    }

    func stopAndWait() async {
        beginSuspension()
        let pending = imports.values.map(\.task)
        for task in pending { _ = await task.result }
        stop()
        let cleanups = Array(cleanups.values)
        for task in cleanups { await task.value }
    }

    func expire() {
        for (token, upload) in uploads where upload.expires <= Date() {
            try? upload.writer.close(); uploads[token] = nil;
            remove(upload.directory, session: upload.handle.session.id)
        }
        targets = targets.filter { $0.value.expires > Date() }
    }

    private func matches(_ handle: Handle, _ session: TerminalEngine.SessionRequest) -> Bool {
        handle.session.id == session.id && handle.session.generation == session.generation
    }
    private func ownedDirectory(_ id: UUID) throws -> URL {
        guard directories.values.reduce(0, { $0 + $1.count }) < 128 else {
            throw ExtensionPeerError.unavailable
        }
        let directory = root.appendingPathComponent(
            "terminal-drop-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        directories[id, default: []].insert(directory)
        return directory
    }
    private func remove(_ directory: URL, session: UUID) {
        directories[session]?.remove(directory); try? FileManager.default.removeItem(at: directory)
    }

    private func importPaths(
        _ request: Paths, session: TerminalEngine.SessionRequest,
        input: @MainActor (Data) throws -> Void
    ) async throws {
        var paths: [String] = []
        var imported: [URL] = []
        var delivered = false
        defer {
            if !delivered {
                for directory in imported { remove(directory, session: session.id) }
            }
        }
        for item in request.items {
            try Task.checkCancellation()
            guard !stopped else { throw ExtensionPeerError.unavailable }
            if !item.temporary { paths.append(item.path); continue }
            let destination = try ownedDirectory(session.id)
            imported.append(destination)
            let target = destination.appendingPathComponent(
                URL(fileURLWithPath: item.path).lastPathComponent)
            let copy = copy
            let task = Task.detached {
                try await copy(URL(fileURLWithPath: item.path), target)
            }
            try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            try Task.checkCancellation()
            paths.append(target.path)
        }
        try Task.checkCancellation()
        guard !stopped else { throw ExtensionPeerError.unavailable }
        try input(Data(paths.map(GhosttyTerminalView.quotePath).joined(separator: " ").utf8))
        delivered = true
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
                    guard bytes <= maximumBytes else { throw CocoaError(.fileWriteOutOfSpace) }
                    try writer.write(contentsOf: chunk)
                }
            }
        }
        try visit(source, target, depth: 0)
    }
}
