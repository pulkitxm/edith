import CryptoKit
import Darwin
import Foundation

public struct UsageSnapshotSource: Sendable {
    public let dataDirectory: URL
    public let usageFile: URL
    public let limitsFile: URL
    public let machinesDirectory: URL

    public init(dataDirectory: URL = Repo.dataDir) {
        self.init(
            dataDirectory: dataDirectory,
            usageFile: dataDirectory.appendingPathComponent("usage.json"),
            limitsFile: dataDirectory.appendingPathComponent("limits-history.jsonl"),
            machinesDirectory: dataDirectory.appendingPathComponent("machines"))
    }

    public init(
        dataDirectory: URL, usageFile: URL, limitsFile: URL, machinesDirectory: URL
    ) {
        self.dataDirectory = dataDirectory
        self.usageFile = usageFile
        self.limitsFile = limitsFile
        self.machinesDirectory = machinesDirectory
    }
}

public struct UsageSnapshotManifest: Codable, Equatable, Sendable {
    public struct File: Codable, Equatable, Sendable {
        public let path: String
        public let bytes: Int64
        public let sha256: String

        public init(path: String, bytes: Int64, sha256: String) {
            self.path = path
            self.bytes = bytes
            self.sha256 = sha256
        }
    }

    public let formatVersion: Int
    public let generation: String
    public let createdAt: Date
    public let files: [File]

    public init(formatVersion: Int, generation: String, createdAt: Date, files: [File]) {
        self.formatVersion = formatVersion
        self.generation = generation
        self.createdAt = createdAt
        self.files = files
    }
}

public struct UsageSnapshotPointer: Codable, Equatable, Sendable {
    public let formatVersion: Int
    public let current: String
    public let previous: String?

    public init(formatVersion: Int, current: String, previous: String?) {
        self.formatVersion = formatVersion
        self.current = current
        self.previous = previous
    }
}

public struct UsageSnapshotPublication: Equatable, Sendable {
    public let directory: URL
    public let manifest: UsageSnapshotManifest
    public let previousGeneration: String?

    public init(
        directory: URL, manifest: UsageSnapshotManifest, previousGeneration: String?
    ) {
        self.directory = directory
        self.manifest = manifest
        self.previousGeneration = previousGeneration
    }
}

public enum UsageSnapshotError: LocalizedError, Equatable, Sendable {
    case empty
    case refreshBusy
    case unsafeFile(String)
    case invalidUsage(String)
    case invalidLimits(String)
    case invalidMachine(String)
    case invalidPointer
    case corruptGeneration(String)
    case generationExists(String)

    public var errorDescription: String? {
        switch self {
        case .empty: "no agent usage data is available to snapshot"
        case .refreshBusy: "agent usage collection is still running"
        case .unsafeFile(let path): "unsafe usage snapshot file at \(path)"
        case .invalidUsage(let path): "usage data at \(path) is invalid"
        case .invalidLimits(let path): "limit history at \(path) is invalid"
        case .invalidMachine(let path): "machine usage data at \(path) is invalid"
        case .invalidPointer: "the usage snapshot pointer is invalid"
        case .corruptGeneration(let generation):
            "usage snapshot generation \(generation) is corrupt"
        case .generationExists(let generation):
            "usage snapshot generation \(generation) already exists"
        }
    }
}

public struct UsageSnapshotHooks: Sendable {
    public var afterStagingFile: @Sendable (String) throws -> Void
    public var beforePointerPublication: @Sendable () throws -> Void

    public init(
        afterStagingFile: @escaping @Sendable (String) throws -> Void = { _ in },
        beforePointerPublication: @escaping @Sendable () throws -> Void = {}
    ) {
        self.afterStagingFile = afterStagingFile
        self.beforePointerPublication = beforePointerPublication
    }

    public static let live = UsageSnapshotHooks()
}

public actor UsageSnapshotStore {
    public static let formatVersion = 1

    private struct Payload: Sendable {
        let path: String
        let data: Data
    }

    private let source: UsageSnapshotSource
    private let root: URL
    private let hooks: UsageSnapshotHooks
    private let manager = FileManager.default

    public init(
        source: UsageSnapshotSource = UsageSnapshotSource(),
        root: URL = Repo.dataDir.appendingPathComponent("usage-snapshots"),
        hooks: UsageSnapshotHooks = .live
    ) {
        self.source = source
        self.root = root
        self.hooks = hooks
    }

    public func publish(
        generation identifier: UUID = UUID(), createdAt: Date = Date()
    ) throws -> UsageSnapshotPublication {
        let payloads = try capture()
        let generation = identifier.uuidString.lowercased()
        try ensureDirectory(root)
        return try withSnapshotLock {
            try publishLocked(payloads, generation: generation, createdAt: createdAt)
        }
    }

    public func current() throws -> UsageSnapshotPublication? {
        try ensureDirectory(root)
        let publication: UsageSnapshotPublication? = try withSnapshotLock {
            guard let pointer = try readPointer() else { return nil }
            let directory = generationsDirectory.appendingPathComponent(pointer.current)
            let manifest = try validateGeneration(at: directory, expected: pointer.current)
            return UsageSnapshotPublication(
                directory: try canonicalURL(directory), manifest: manifest,
                previousGeneration: pointer.previous)
        }
        return publication
    }

    private var generationsDirectory: URL {
        root.appendingPathComponent("generations", isDirectory: true)
    }

    private var pointerFile: URL {
        root.appendingPathComponent("current.json")
    }

    private func capture() throws -> [Payload] {
        do {
            return try UsageDataTransaction.withExclusiveAccess(
                dataDirectory: source.dataDirectory
            ) {
                let payloads = try captureLocked()
                guard !payloads.isEmpty else { throw UsageSnapshotError.empty }
                return payloads.sorted { $0.path < $1.path }
            }
        } catch UsageDataTransactionError.refreshBusy {
            throw UsageSnapshotError.refreshBusy
        }
    }

    private func captureLocked() throws -> [Payload] {
        var payloads: [Payload] = []
        if manager.fileExists(atPath: source.usageFile.path) {
            let data = try regularFileData(at: source.usageFile)
            guard let normalized = UsageHistory.merge(local: data, cloud: nil),
                UsageHistory.isValidDocument(normalized)
            else { throw UsageSnapshotError.invalidUsage(source.usageFile.path) }
            payloads.append(Payload(path: "usage.json", data: normalized))
        }
        if manager.fileExists(atPath: source.limitsFile.path) {
            let data = try regularFileData(at: source.limitsFile)
            guard let text = String(data: data, encoding: .utf8) else {
                throw UsageSnapshotError.unsafeFile(source.limitsFile.path)
            }
            let validated = try normalizedLimitsSnapshot(text, path: source.limitsFile.path)
            payloads.append(Payload(path: "limits-history.jsonl", data: Data(validated.utf8)))
        }
        payloads.append(contentsOf: try machinePayloads())
        return payloads
    }

    private func machinePayloads() throws -> [Payload] {
        guard manager.fileExists(atPath: source.machinesDirectory.path) else { return [] }
        let directoryValues = try source.machinesDirectory.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard directoryValues.isDirectory == true, directoryValues.isSymbolicLink != true else {
            throw UsageSnapshotError.unsafeFile(source.machinesDirectory.path)
        }
        let files = try manager.contentsOfDirectory(
            at: source.machinesDirectory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        return try files.sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap {
            file in
            guard file.pathExtension == "json",
                let identifier = UUID(uuidString: file.deletingPathExtension().lastPathComponent)
            else { return nil }
            let data = try regularFileData(at: file)
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                object["daily"] is [Any],
                let machine = object["machine"] as? [String: Any],
                let embedded = machine["id"] as? String,
                UUID(uuidString: embedded) == identifier,
                let collectedAt = machine["collectedAt"] as? String,
                EdithDate.parseISO(collectedAt) != nil
            else {
                throw UsageSnapshotError.invalidMachine(
                    source.machinesDirectory.appendingPathComponent(file.lastPathComponent).path)
            }
            return Payload(path: "machines/\(identifier.uuidString.lowercased()).json", data: data)
        }
    }

    private func regularFileData(at url: URL) throws -> Data {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw UsageSnapshotError.unsafeFile(url.path)
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else {
            try? handle.close()
            throw UsageSnapshotError.unsafeFile(url.path)
        }
        guard metadata.st_mode & S_IFMT == S_IFREG else {
            try? handle.close()
            throw UsageSnapshotError.unsafeFile(url.path)
        }
        do {
            let data = try handle.readToEnd() ?? Data()
            try handle.close()
            return data
        } catch {
            try? handle.close()
            throw error
        }
    }

    private func publishLocked(
        _ payloads: [Payload], generation: String, createdAt: Date
    ) throws -> UsageSnapshotPublication {
        try ensureDirectory(root)
        try ensureDirectory(generationsDirectory)
        let destination = generationsDirectory.appendingPathComponent(generation)
        guard !manager.fileExists(atPath: destination.path) else {
            throw UsageSnapshotError.generationExists(generation)
        }
        let existing = try readPointer()
        if let existing {
            let current = generationsDirectory.appendingPathComponent(existing.current)
            guard manager.fileExists(atPath: current.path) else {
                throw UsageSnapshotError.invalidPointer
            }
        }
        let staging = generationsDirectory.appendingPathComponent(".pending-\(generation)")
        try? manager.removeItem(at: staging)
        try ensureDirectory(staging)
        var promoted = false
        defer {
            if !promoted { try? manager.removeItem(at: staging) }
        }
        var files: [UsageSnapshotManifest.File] = []
        for payload in payloads {
            let target = staging.appendingPathComponent(payload.path)
            try ensureDirectory(target.deletingLastPathComponent())
            try UsageDurableFile.write(payload.data, to: target)
            files.append(
                UsageSnapshotManifest.File(
                    path: payload.path, bytes: Int64(payload.data.count),
                    sha256: Self.digest(payload.data)))
            try hooks.afterStagingFile(payload.path)
        }
        let manifest = UsageSnapshotManifest(
            formatVersion: Self.formatVersion, generation: generation, createdAt: createdAt,
            files: files)
        let manifestData = try Self.encode(manifest)
        let persistedManifest = try Self.decode(UsageSnapshotManifest.self, from: manifestData)
        try UsageDurableFile.write(
            manifestData, to: staging.appendingPathComponent("manifest.json"))
        try UsageDurableFile.synchronize(staging)
        guard Darwin.rename(staging.path, destination.path) == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
        promoted = true
        try UsageDurableFile.synchronize(generationsDirectory)
        try hooks.beforePointerPublication()
        let pointer = UsageSnapshotPointer(
            formatVersion: Self.formatVersion, current: generation,
            previous: existing?.current)
        try UsageDurableFile.write(try Self.encode(pointer), to: pointerFile)
        cleanupGenerations(keeping: Set([pointer.current, pointer.previous].compactMap { $0 }))
        return UsageSnapshotPublication(
            directory: try canonicalURL(destination), manifest: persistedManifest,
            previousGeneration: pointer.previous)
    }

    private func readPointer() throws -> UsageSnapshotPointer? {
        guard manager.fileExists(atPath: pointerFile.path) else { return nil }
        let data = try regularFileData(at: pointerFile)
        guard let pointer = try? Self.decode(UsageSnapshotPointer.self, from: data),
            pointer.formatVersion == Self.formatVersion,
            UUID(uuidString: pointer.current) != nil,
            pointer.previous.map({ UUID(uuidString: $0) != nil }) ?? true
        else { throw UsageSnapshotError.invalidPointer }
        return pointer
    }

    private func validateGeneration(at directory: URL, expected generation: String) throws
        -> UsageSnapshotManifest
    {
        do {
            let data = try regularFileData(at: directory.appendingPathComponent("manifest.json"))
            let manifest = try Self.decode(UsageSnapshotManifest.self, from: data)
            guard manifest.formatVersion == Self.formatVersion,
                manifest.generation == generation,
                Set(manifest.files.map(\.path)).count == manifest.files.count
            else { throw UsageSnapshotError.corruptGeneration(generation) }
            for file in manifest.files {
                guard Self.allowed(path: file.path) else {
                    throw UsageSnapshotError.corruptGeneration(generation)
                }
                let payload = try regularFileData(at: directory.appendingPathComponent(file.path))
                guard payload.count == file.bytes, Self.digest(payload) == file.sha256 else {
                    throw UsageSnapshotError.corruptGeneration(generation)
                }
                try validatePayload(payload, path: file.path)
            }
            let actual = try relativeFiles(in: directory)
            let expected = Set(manifest.files.map(\.path) + ["manifest.json"])
            guard actual == expected else {
                throw UsageSnapshotError.corruptGeneration(generation)
            }
            return manifest
        } catch let error as UsageSnapshotError {
            throw error
        } catch {
            throw UsageSnapshotError.corruptGeneration(generation)
        }
    }

    private func validatePayload(_ data: Data, path: String) throws {
        if path == "usage.json" {
            guard UsageHistory.isValidDocument(data)
            else { throw UsageSnapshotError.invalidUsage(path) }
            return
        }
        if path == "limits-history.jsonl" {
            guard let text = String(data: data, encoding: .utf8),
                (try? normalizedLimitsSnapshot(text, path: path)) == text
            else { throw UsageSnapshotError.invalidLimits(path) }
            return
        }
        guard path.hasPrefix("machines/"),
            let identifier = UUID(
                uuidString: String(path.dropFirst("machines/".count).dropLast(".json".count))),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            object["daily"] is [Any],
            let machine = object["machine"] as? [String: Any],
            let embedded = machine["id"] as? String,
            UUID(uuidString: embedded) == identifier,
            let collectedAt = machine["collectedAt"] as? String,
            EdithDate.parseISO(collectedAt) != nil
        else { throw UsageSnapshotError.invalidMachine(path) }
    }

    private func relativeFiles(in directory: URL) throws -> Set<String> {
        guard
            let enumerator = manager.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        else { throw UsageSnapshotError.unsafeFile(directory.path) }
        var files = Set<String>()
        var resolved = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(directory.path, &resolved) != nil else {
            throw UsageSnapshotError.unsafeFile(directory.path)
        }
        let prefix = String(cString: resolved) + "/"
        while let file = enumerator.nextObject() as? URL {
            let values = try file.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else {
                throw UsageSnapshotError.unsafeFile(file.path)
            }
            if values.isDirectory == true { continue }
            guard file.path.hasPrefix(prefix) else {
                throw UsageSnapshotError.unsafeFile(file.path)
            }
            files.insert(String(file.path.dropFirst(prefix.count)))
        }
        return files
    }

    private func cleanupGenerations(keeping: Set<String>) {
        guard
            let entries = try? manager.contentsOfDirectory(
                at: generationsDirectory, includingPropertiesForKeys: nil)
        else { return }
        var changed = false
        for entry in entries where !keeping.contains(entry.lastPathComponent) {
            let name = entry.lastPathComponent
            guard UUID(uuidString: name) != nil || name.hasPrefix(".pending-") else { continue }
            if (try? manager.removeItem(at: entry)) != nil { changed = true }
        }
        if changed { try? UsageDurableFile.synchronize(generationsDirectory) }
    }

    private func withSnapshotLock<T>(_ body: () throws -> T) throws -> T {
        let lock = try UsageDataLock.acquire(at: root.appendingPathComponent("snapshot.lock"))
        defer { lock.release() }
        return try body()
    }

    private func normalizedLimitsSnapshot(_ text: String, path: String) throws -> String {
        let ended = text.hasSuffix("\n")
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var valid: [String] = []
        for (index, line) in lines.enumerated() where !line.isEmpty {
            let document = String(line) + "\n"
            guard LimitsHistory.isValidDocument(document) else {
                if index == lines.count - 1, !ended { continue }
                if line.utf8.count > 1_048_576 { continue }
                throw UsageSnapshotError.invalidLimits(path)
            }
            valid.append(String(line))
        }
        guard !valid.isEmpty else { throw UsageSnapshotError.invalidLimits(path) }
        let normalized = LimitsHistory.merge(valid.joined(separator: "\n"), "")
        guard LimitsHistory.isValidDocument(normalized) else {
            throw UsageSnapshotError.invalidLimits(path)
        }
        return normalized
    }

    private func ensureDirectory(_ url: URL) throws {
        if manager.fileExists(atPath: url.path) {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw UsageSnapshotError.unsafeFile(url.path)
            }
        } else {
            try manager.createDirectory(at: url, withIntermediateDirectories: true)
        }
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private func canonicalURL(_ url: URL) throws -> URL {
        var resolved = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(url.path, &resolved) != nil else {
            throw UsageSnapshotError.unsafeFile(url.path)
        }
        return URL(fileURLWithPath: String(cString: resolved))
    }

    private static func allowed(path: String) -> Bool {
        if path == "usage.json" || path == "limits-history.jsonl" { return true }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 2, components[0] == "machines" else { return false }
        let file = String(components[1])
        return file.hasSuffix(".json")
            && UUID(uuidString: String(file.dropLast(".json".count))) != nil
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }
}
