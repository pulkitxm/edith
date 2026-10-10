import EdithExtensionSupport
import Foundation

struct OwnedTerminalDropRequest: Codable {
    let session: OwnedTerminalHandle
    var names: [String]? = nil
    var paths: [String]? = nil
    var token: UUID? = nil
    var index: Int? = nil
    var offset: UInt64? = nil
    var bytes: Data? = nil
}

struct OwnedTerminalDropReceipt: Codable {
    var token: UUID? = nil
    var offset: UInt64? = nil
    var paths: [String]? = nil
    var state: String? = nil
}

@MainActor final class OwnedTerminalFiles {
    typealias Upload = @MainActor (OwnedTerminalHandle, [URL]) async throws -> [String]
    private struct Group {
        let session: OwnedTerminalHandle
        let directory: URL
        let files: [URL]
        var writers: [FileHandle]
        var offsets: [UInt64]
        var expires: Date
    }
    private struct Completed { let session: OwnedTerminalHandle; let paths: [String] }
    private var groups: [UUID: Group] = [:]
    private var completed: [UUID: Completed] = [:]
    private var completedOrder: [UUID] = []
    private var directories: [UUID: Set<URL>] = [:]
    private var transfers: [UUID: Task<[String], Error>] = [:]
    private var transferOwners: [UUID: OwnedTerminalHandle] = [:]
    private var observers: [UUID: Task<Void, Never>] = [:]
    private var failures: [UUID: (OwnedTerminalHandle, String)] = [:]
    private var expiry: Task<Void, Never>?
    private var stopped = false
    var upload: Upload?
    deinit { expiry?.cancel() }
    static let maximumBytes: UInt64 = 536_870_912

    static func admits(_ operation: String) -> Bool {
        ["begin", "write", "finish", "status", "cancel", "paths"].contains {
            operation == OwnedTerminalSession.owner + ".terminal.drop." + $0
        }
    }

    func execute(_ operation: String, payload: Data, session: OwnedTerminalHandle, local: Bool)
        async throws -> Data
    {
        guard !stopped,
            let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any]
        else { throw ExtensionPeerError.unavailable }
        expire()
        let request = try JSONDecoder().decode(OwnedTerminalDropRequest.self, from: payload)
        guard request.session == session else { throw ExtensionPeerError.invalidRequest }
        let prefix = OwnedTerminalSession.owner + ".terminal.drop."
        switch operation {
        case prefix + "paths":
            guard local, Set(object.keys) == ["session", "paths"], let paths = request.paths,
                !paths.isEmpty, paths.count <= 64,
                paths.allSatisfy({
                    $0.hasPrefix("/") && $0.utf8.count <= 4096 && !$0.utf8.contains(0)
                })
            else { throw ExtensionPeerError.invalidRequest }
            return try JSONEncoder().encode(OwnedTerminalDropReceipt(paths: paths))
        case prefix + "begin":
            guard Set(object.keys) == ["session", "names"], let names = request.names,
                !names.isEmpty, names.count <= 64, groups.count < 8,
                local || upload != nil,
                directories.values.reduce(0, { $0 + $1.count }) < 128,
                names.allSatisfy({
                    !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.count <= 255
                        && !$0.contains("/") && !$0.contains("\\")
                        && !$0.unicodeScalars.contains(
                            where: CharacterSet.controlCharacters.contains)
                })
            else { throw ExtensionPeerError.invalidRequest }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                "edith-" + OwnedTerminalSession.owner + "-drop-" + UUID().uuidString)
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            var writers: [FileHandle] = []
            var files: [URL] = []
            do {
                for (index, name) in names.enumerated() {
                    let container = directory.appendingPathComponent(String(index))
                    try FileManager.default.createDirectory(
                        at: container, withIntermediateDirectories: false,
                        attributes: [.posixPermissions: 0o700])
                    let file = container.appendingPathComponent(name)
                    guard
                        FileManager.default.createFile(
                            atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]
                        )
                    else { throw CocoaError(.fileWriteUnknown) }
                    writers.append(try FileHandle(forWritingTo: file))
                    files.append(file)
                }
            } catch {
                writers.forEach { try? $0.close() }
                try? FileManager.default.removeItem(at: directory)
                throw error
            }
            let token = UUID()
            directories[session.id, default: []].insert(directory)
            groups[token] = Group(
                session: session, directory: directory, files: files, writers: writers,
                offsets: Array(repeating: 0, count: files.count),
                expires: Date().addingTimeInterval(60))
            if expiry == nil {
                expiry = Task { [weak self] in
                    while !Task.isCancelled {
                        do { try await Task.sleep(for: .seconds(1)) } catch { return };
                        self?.expire()
                    }
                }
            }
            return try JSONEncoder().encode(OwnedTerminalDropReceipt(token: token))
        case prefix + "write":
            guard Set(object.keys) == ["session", "token", "index", "offset", "bytes"],
                let token = request.token, var group = groups[token], group.session == session,
                transfers[token] == nil, let index = request.index,
                group.files.indices.contains(index),
                let offset = request.offset, offset == group.offsets[index],
                let bytes = request.bytes, !bytes.isEmpty, bytes.count <= 16384,
                group.offsets.reduce(0, +) + UInt64(bytes.count) <= Self.maximumBytes
            else { throw ExtensionPeerError.invalidRequest }
            try group.writers[index].write(contentsOf: bytes)
            group.offsets[index] += UInt64(bytes.count)
            group.expires = Date().addingTimeInterval(60)
            groups[token] = group
            return try JSONEncoder().encode(OwnedTerminalDropReceipt(offset: group.offsets[index]))
        case prefix + "finish", prefix + "status":
            guard Set(object.keys) == ["session", "token"], let token = request.token else {
                throw ExtensionPeerError.invalidRequest
            }
            if let result = completed[token], result.session == session {
                return try JSONEncoder().encode(
                    OwnedTerminalDropReceipt(paths: result.paths, state: "complete"))
            }
            if let failure = failures[token], failure.0 == session {
                throw ExtensionPeerError.rejected(failure.1)
            }
            guard var group = groups[token], group.session == session else {
                throw ExtensionPeerError.invalidRequest
            }
            if transfers[token] != nil {
                return try JSONEncoder().encode(
                    OwnedTerminalDropReceipt(token: token, state: "running"))
            }
            guard operation == prefix + "finish" else { throw ExtensionPeerError.invalidRequest }
            for writer in group.writers { try writer.close() }
            group.writers = []
            groups[token] = group
            let uploader = upload
            let task = Task {
                if local { return group.files.map(\.path) }
                guard let uploader else { throw ExtensionPeerError.unavailable }
                return try await uploader(session, group.files)
            }
            transfers[token] = task
            transferOwners[token] = session
            observers[token] = Task { [weak self] in
                let result = await task.result
                self?.complete(token, group: group, local: local, result: result)
            }
            return try JSONEncoder().encode(
                OwnedTerminalDropReceipt(token: token, state: "running"))
        case prefix + "cancel":
            guard Set(object.keys) == ["session", "token"], let token = request.token,
                let group = groups[token], group.session == session
            else { throw ExtensionPeerError.invalidRequest }
            if let transfer = transfers[token] {
                transfer.cancel()
                _ = await transfer.result
                await observers[token]?.value
            } else {
                groups[token] = nil
                group.writers.forEach { try? $0.close() }
                remove(group.directory, session: session.id)
            }
        default: throw ExtensionPeerError.invalidRequest
        }
        return Data("{}".utf8)
    }

    private func complete(_ token: UUID, group: Group, local: Bool, result: Result<[String], Error>)
    {
        transfers[token] = nil
        transferOwners[token] = nil
        observers[token] = nil
        guard !stopped, groups[token]?.session == group.session else {
            remove(group.directory, session: group.session.id); return
        }
        groups[token] = nil
        completedOrder.append(token)
        if completedOrder.count > 512 {
            let expired = completedOrder.removeFirst(); completed[expired] = nil;
            failures[expired] = nil
        }
        switch result {
        case let .success(paths)
        where paths.count == group.files.count
            && paths.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 4096 && !$0.utf8.contains(0) }):
            completed[token] = .init(session: group.session, paths: paths)
            if !local { remove(group.directory, session: group.session.id) }
        case .success:
            failures[token] = (group.session, "The terminal upload returned invalid paths.")
            remove(group.directory, session: group.session.id)
        case let .failure(error):
            failures[token] = (group.session, String(error.localizedDescription.prefix(4096)))
            remove(group.directory, session: group.session.id)
        }
    }

    func drainRetired(_ active: (OwnedTerminalHandle) -> Bool) async {
        await drain(transferOwners.values.filter { !active($0) })
    }

    func drain(_ sessions: [OwnedTerminalHandle]) async {
        let tokens = transferOwners.compactMap { sessions.contains($0.value) ? $0.key : nil }
        let jobs = tokens.compactMap { transfers[$0] }
        let observing = tokens.compactMap { observers[$0] }
        for task in jobs { _ = await task.result }
        for task in observing { await task.value }
    }

    func stopAndWait() async {
        let pending = Array(transfers.values)
        let observing = Array(observers.values)
        stop()
        for task in pending { _ = await task.result }
        for task in observing { await task.value }
    }

    func close(_ session: OwnedTerminalHandle) {
        for (token, group) in groups where group.session == session {
            transfers[token]?.cancel()
            groups[token] = nil
            group.writers.forEach { try? $0.close() }
        }
        completed = completed.filter { $0.value.session != session }
        failures = failures.filter { $0.value.0 != session }
        for directory in directories.removeValue(forKey: session.id) ?? [] {
            try? FileManager.default.removeItem(at: directory)
        }
    }
    func stop() {
        stopped = true
        expiry?.cancel(); expiry = nil
        transfers.values.forEach { $0.cancel() }
        for group in Array(groups.values) { close(group.session) }
        for id in Array(directories.keys) {
            for directory in directories.removeValue(forKey: id) ?? [] {
                try? FileManager.default.removeItem(at: directory)
            }
        }
        completed.removeAll()
    }
    private func expire() {
        for (token, group) in groups where group.expires <= Date() && transfers[token] == nil {
            groups[token] = nil
            group.writers.forEach { try? $0.close() }
            remove(group.directory, session: group.session.id)
        }
    }
    private func remove(_ directory: URL, session: UUID) {
        directories[session]?.remove(directory)
        try? FileManager.default.removeItem(at: directory)
    }
}
