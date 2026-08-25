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
    case duplicatePayload(String)
    case oversizedFile(String)

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
        case .duplicatePayload(let path): "duplicate usage snapshot payload at \(path)"
        case .oversizedFile(let path): "usage snapshot file is too large at \(path)"
        }
    }
}

public struct UsageSnapshotHooks: Sendable {
    public var afterCapture: @Sendable () throws -> Void
    public var afterStagingFile: @Sendable (String) throws -> Void
    public var beforePointerPublication: @Sendable () throws -> Void
    public var beforePointerRepair: @Sendable () throws -> Void

    public init(
        afterCapture: @escaping @Sendable () throws -> Void = {},
        afterStagingFile: @escaping @Sendable (String) throws -> Void = { _ in },
        beforePointerPublication: @escaping @Sendable () throws -> Void = {},
        beforePointerRepair: @escaping @Sendable () throws -> Void = {}
    ) {
        self.afterCapture = afterCapture
        self.afterStagingFile = afterStagingFile
        self.beforePointerPublication = beforePointerPublication
        self.beforePointerRepair = beforePointerRepair
    }

    public static let live = UsageSnapshotHooks()
}

struct UsageSnapshotBounds: Sendable {
    var maximumUsageBytes = UsageDataFiles.maximumUsageDocumentBytes
    var maximumLimitsBytes = UsageDataFiles.maximumLimitsHistoryBytes
    var maximumMachineBytes = UsageDataFiles.maximumMachineDocumentBytes
    var maximumPointerBytes = 64 * 1_024
    var maximumManifestBytes = 1 * 1_024 * 1_024
    var maximumInspectedMachineEntries = MachineUsageStore.maximumInspectedMachineEntries
    var maximumMachineDocuments = MachineUsageStore.maximumMachineDocuments
    var maximumMachineAggregateBytes = MachineUsageStore.maximumMachineDocumentBytesPerScan

    static let live = UsageSnapshotBounds()
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
    private let bounds: UsageSnapshotBounds
    private let manager = FileManager.default

    public init(
        source: UsageSnapshotSource = UsageSnapshotSource(),
        root: URL = Repo.dataDir.appendingPathComponent("usage-snapshots"),
        hooks: UsageSnapshotHooks = .live
    ) {
        self.source = source
        self.root = root
        self.hooks = hooks
        self.bounds = .live
    }

    init(
        source: UsageSnapshotSource, root: URL, hooks: UsageSnapshotHooks = .live,
        bounds: UsageSnapshotBounds
    ) {
        self.source = source
        self.root = root
        self.hooks = hooks
        self.bounds = bounds
    }

    public func publish(
        generation identifier: UUID = UUID(), createdAt: Date = Date()
    ) throws -> UsageSnapshotPublication {
        let generation = identifier.uuidString.lowercased()
        try ensureDirectory(root)
        return try withSnapshotLock {
            let payloads = try capture()
            try hooks.afterCapture()
            return try publishLocked(payloads, generation: generation, createdAt: createdAt)
        }
    }

    public func current() throws -> UsageSnapshotPublication? {
        try ensureDirectory(root)
        let publication: UsageSnapshotPublication? = try withSnapshotLock {
            try validatedPublication()
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
                var paths = Set<String>()
                for payload in payloads where !paths.insert(payload.path).inserted {
                    throw UsageSnapshotError.duplicatePayload(payload.path)
                }
                return payloads.sorted { $0.path < $1.path }
            }
        } catch UsageDataTransactionError.refreshBusy {
            throw UsageSnapshotError.refreshBusy
        }
    }

    private func captureLocked() throws -> [Payload] {
        var payloads: [Payload] = []
        if manager.fileExists(atPath: source.usageFile.path) {
            let data = try regularFileData(
                at: source.usageFile, maximumBytes: bounds.maximumUsageBytes)
            guard let projected = Self.projectUsage(data, requiresMachine: false)
            else { throw UsageSnapshotError.invalidUsage(source.usageFile.path) }
            payloads.append(Payload(path: "usage.json", data: projected))
        }
        if manager.fileExists(atPath: source.limitsFile.path) {
            let data = try regularFileData(
                at: source.limitsFile, maximumBytes: bounds.maximumLimitsBytes)
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
            let data = try regularFileData(at: file, maximumBytes: bounds.maximumMachineBytes)
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let machine = object["machine"] as? [String: Any],
                let embedded = machine["id"] as? String,
                UUID(uuidString: embedded) == identifier,
                let collectedAt = machine["collectedAt"] as? String,
                EdithDate.parseISO(collectedAt) != nil,
                let projected = Self.projectUsage(data, requiresMachine: true)
            else {
                throw UsageSnapshotError.invalidMachine(
                    source.machinesDirectory.appendingPathComponent(file.lastPathComponent).path)
            }
            return Payload(
                path: "machines/\(identifier.uuidString.lowercased()).json", data: projected)
        }
    }

    private func regularFileData(at url: URL, maximumBytes: Int) throws -> Data {
        guard maximumBytes >= 0, maximumBytes < Int.max else {
            throw UsageSnapshotError.oversizedFile(url.path)
        }
        do {
            guard
                let data = try UsageDataFiles.readRegularFile(
                    at: url, maximumBytes: maximumBytes)
            else {
                throw UsageSnapshotError.unsafeFile(url.path)
            }
            return data
        } catch UsageDataFileError.unsafe(_) {
            throw UsageSnapshotError.unsafeFile(url.path)
        } catch UsageDataFileError.oversized(_) {
            throw UsageSnapshotError.oversizedFile(url.path)
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
        let existing: UsageSnapshotPublication?
        do {
            existing = try validatedPublication()
        } catch is UsageSnapshotError {
            existing = nil
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
        guard try validateGeneration(at: destination, expected: generation) == persistedManifest
        else { throw UsageSnapshotError.corruptGeneration(generation) }
        try hooks.beforePointerPublication()
        let pointer = UsageSnapshotPointer(
            formatVersion: Self.formatVersion, current: generation,
            previous: existing?.manifest.generation)
        try UsageDurableFile.write(try Self.encode(pointer), to: pointerFile)
        cleanupGenerations(keeping: Set([pointer.current, pointer.previous].compactMap { $0 }))
        return UsageSnapshotPublication(
            directory: try canonicalURL(destination), manifest: persistedManifest,
            previousGeneration: pointer.previous)
    }

    private func readPointer() throws -> UsageSnapshotPointer? {
        guard manager.fileExists(atPath: pointerFile.path) else { return nil }
        let data = try regularFileData(
            at: pointerFile, maximumBytes: bounds.maximumPointerBytes)
        guard let pointer = try? Self.decode(UsageSnapshotPointer.self, from: data),
            pointer.formatVersion == Self.formatVersion,
            UUID(uuidString: pointer.current) != nil,
            pointer.previous.map({ UUID(uuidString: $0) != nil }) ?? true
        else { throw UsageSnapshotError.invalidPointer }
        return pointer
    }

    private func validatedPublication() throws -> UsageSnapshotPublication? {
        guard let pointer = try readPointer() else { return nil }
        do {
            return try publication(
                generation: pointer.current, previousGeneration: pointer.previous)
        } catch let currentError {
            guard let previous = pointer.previous else { throw currentError }
            do {
                let recovered = try publication(
                    generation: previous, previousGeneration: nil)
                do {
                    try hooks.beforePointerRepair()
                    let repaired = UsageSnapshotPointer(
                        formatVersion: Self.formatVersion, current: previous, previous: nil)
                    try UsageDurableFile.write(try Self.encode(repaired), to: pointerFile)
                    cleanupGenerations(keeping: Set([previous]))
                } catch {}
                return recovered
            } catch {
                throw currentError
            }
        }
    }

    private func publication(
        generation: String, previousGeneration: String?
    ) throws -> UsageSnapshotPublication {
        let directory = generationsDirectory.appendingPathComponent(generation)
        let manifest = try validateGeneration(at: directory, expected: generation)
        return UsageSnapshotPublication(
            directory: try canonicalURL(directory), manifest: manifest,
            previousGeneration: previousGeneration)
    }

    private func validateGeneration(at directory: URL, expected generation: String) throws
        -> UsageSnapshotManifest
    {
        do {
            try validateDirectory(directory)
            let manifestURL = directory.appendingPathComponent("manifest.json")
            let data = try regularFileData(
                at: manifestURL, maximumBytes: bounds.maximumManifestBytes)
            let manifest = try Self.decode(UsageSnapshotManifest.self, from: data)
            guard manifest.formatVersion == Self.formatVersion,
                manifest.generation == generation,
                Set(manifest.files.map(\.path)).count == manifest.files.count
            else { throw UsageSnapshotError.corruptGeneration(generation) }
            for file in manifest.files {
                guard Self.allowed(path: file.path) else {
                    throw UsageSnapshotError.corruptGeneration(generation)
                }
                let maximumBytes = maximumPayloadBytes(path: file.path)
                guard file.bytes >= 0, file.bytes <= Int64(maximumBytes) else {
                    throw UsageSnapshotError.corruptGeneration(generation)
                }
                let payload = try regularFileData(
                    at: directory.appendingPathComponent(file.path),
                    maximumBytes: maximumBytes)
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
            guard Self.projectUsage(data, requiresMachine: false) == data
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
            EdithDate.parseISO(collectedAt) != nil,
            Self.projectUsage(data, requiresMachine: true) == data
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

    private func validateDirectory(_ url: URL) throws {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFDIR else {
            throw UsageSnapshotError.unsafeFile(url.path)
        }
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

    private func maximumPayloadBytes(path: String) -> Int {
        if path == "usage.json" { return bounds.maximumUsageBytes }
        if path == "limits-history.jsonl" { return bounds.maximumLimitsBytes }
        return bounds.maximumMachineBytes
    }

    private static func projectUsage(_ data: Data, requiresMachine: Bool) -> Data? {
        guard let normalized = UsageHistory.merge(local: data, cloud: nil),
            let object = try? JSONSerialization.jsonObject(with: normalized) as? [String: Any],
            object["daily"] is [[String: Any]],
            !requiresMachine || object["machine"] is [String: Any]
        else { return nil }
        let projected = projectRoot(object, requiresMachine: requiresMachine)
        guard JSONSerialization.isValidJSONObject(projected),
            let encoded = try? JSONSerialization.data(
                withJSONObject: projected, options: [.sortedKeys]),
            UsageHistory.isValidDocument(encoded)
        else { return nil }
        return encoded
    }

    private static func projectRoot(
        _ object: [String: Any], requiresMachine: Bool
    ) -> [String: Any] {
        var result = primitives(object, ["schemaVersion", "generatedAt"])
        if let sources = object["sources"] as? [String] { result["sources"] = sources }
        if let sources = object["defaultSources"] as? [String] {
            result["defaultSources"] = sources
        }
        if let sourceMeta = object["sourceMeta"] as? [String: Any] {
            result["sourceMeta"] = map(sourceMeta) {
                primitives(
                    $0, ["label", "tool", "machine", "machineID", "machineHost"])
            }
        }
        if let totals = object["totals"] as? [String: Any] {
            result["totals"] = projectTotals(totals)
        }
        if let daily = object["daily"] as? [[String: Any]] {
            result["daily"] = daily.map(projectDay)
        }
        if let sessions = object["sessions"] as? [[String: Any]] {
            result["sessions"] = sessions.map {
                primitives($0, ["id", "source", "totalTokens", "cost"])
            }
        }
        if let machines = object["machines"] as? [[String: Any]] {
            result["machines"] = machines.map(projectMachine)
        }
        if requiresMachine, let machine = object["machine"] as? [String: Any] {
            result["machine"] = projectMachine(machine)
        }
        return result
    }

    private static func projectTotals(_ object: [String: Any]) -> [String: Any] {
        var result = primitives(
            object,
            [
                "cost", "tokens", "inputTokens", "outputTokens", "cacheCreationTokens",
                "cacheReadTokens",
            ])
        if let sources = object["bySource"] as? [String: Any] {
            result["bySource"] = map(sources) { primitives($0, ["cost", "tokens"]) }
        }
        return result
    }

    private static func projectDay(_ object: [String: Any]) -> [String: Any] {
        var result = primitives(object, ["period"])
        if let sources = object["bySource"] as? [String: Any] {
            result["bySource"] = mapArrays(sources) { projectModel($0) }
        }
        if let hours = object["hours"] as? [[String: Any]] {
            result["hours"] = hours.map(projectHour)
        }
        if let projects = object["projects"] as? [[String: Any]] {
            result["projects"] = projects.map(projectProject)
        }
        return result
    }

    private static func projectModel(_ object: [String: Any]) -> [String: Any] {
        primitives(
            object,
            [
                "modelName", "inputTokens", "outputTokens", "cacheCreationTokens",
                "cacheReadTokens", "cost",
            ])
    }

    private static func projectHour(_ object: [String: Any]) -> [String: Any] {
        var result = projectDetailNode(object)
        if let paths = object["byPath"] as? [String: Any] {
            result["byPath"] = map(paths) { projectDetailNode($0) }
        }
        return result
    }

    private static func projectDetailNode(_ object: [String: Any]) -> [String: Any] {
        var result = primitives(object, ["tokens", "cost"])
        if let sources = object["bySource"] as? [String: Any] {
            result["bySource"] = map(sources) { source in
                var projected = primitives(source, ["tokens", "cost"])
                if let models = source["byModel"] as? [String: Any] {
                    projected["byModel"] = map(models) {
                        primitives($0, ["tokens", "cost"])
                    }
                }
                return projected
            }
        }
        return result
    }

    private static func projectProject(_ object: [String: Any]) -> [String: Any] {
        var result = projectDetailNode(object)
        result.merge(
            primitives(
                object,
                [
                    "projectName", "repositoryID", "repositoryName", "repositoryURL",
                    "folderName", "path", "machineName", "machineID",
                ]),
            uniquingKeysWith: { _, new in new })
        if let chats = object["chats"] as? [[String: Any]] {
            result["chats"] = chats.map(projectChat)
        }
        if let worktrees = object["worktrees"] as? [[String: Any]] {
            result["worktrees"] = worktrees.map { worktree in
                var projected = primitives(worktree, ["name", "tokens", "cost"])
                if let chats = worktree["chats"] as? [[String: Any]] {
                    projected["chats"] = chats.map(projectChat)
                }
                return projected
            }
        }
        return result
    }

    private static func projectChat(_ object: [String: Any]) -> [String: Any] {
        primitives(
            object,
            ["id", "path", "title", "tokens", "cost", "firstTs", "lastTs", "source"])
    }

    private static func projectMachine(_ object: [String: Any]) -> [String: Any] {
        var result = primitives(object, ["id", "name", "slug", "host", "collectedAt"])
        if let sources = object["sources"] as? [String] { result["sources"] = sources }
        return result
    }

    private static func primitives(
        _ object: [String: Any], _ keys: [String]
    ) -> [String: Any] {
        keys.reduce(into: [:]) { result, key in
            guard let value = object[key], value is String || value is NSNumber || value is NSNull
            else { return }
            result[key] = value
        }
    }

    private static func map(
        _ object: [String: Any], _ project: ([String: Any]) -> [String: Any]
    ) -> [String: Any] {
        object.reduce(into: [:]) { result, entry in
            guard let value = entry.value as? [String: Any] else { return }
            result[entry.key] = project(value)
        }
    }

    private static func mapArrays(
        _ object: [String: Any], _ project: ([String: Any]) -> [String: Any]
    ) -> [String: Any] {
        object.reduce(into: [:]) { result, entry in
            guard let values = entry.value as? [[String: Any]] else { return }
            result[entry.key] = values.map(project)
        }
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
