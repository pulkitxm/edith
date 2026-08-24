import EdithCore
import Darwin
import Foundation

public enum ShelfMutationOperation: String, CaseIterable, Sendable {
    case add
    case addText = "add-text"
    case update
    case remove = "rm"
    case clear
    case purge

    public var descriptor: UserOperationDescriptor {
        UserOperationDescriptor(
            id: UserOperationID(rawValue: "shelf.\(rawValue)"), summary: summary,
            cli: ["shelf", rawValue], effect: effect,
            requiresPreview: self == .remove || self == .clear || self == .purge)
    }

    private var summary: String {
        switch self {
        case .add: return "Copy a file onto the shelf."
        case .addText: return "Add text to the shelf."
        case .update: return "Update shelf item positions."
        case .remove: return "Remove shelf items."
        case .clear: return "Empty the shelf."
        case .purge: return "Remove expired shelf items."
        }
    }

    private var effect: UserOperationEffect {
        switch self {
        case .add, .addText, .update: return .write
        case .remove, .clear, .purge: return .destructive
        }
    }
}

public struct ShelfMutationResult: Equatable, Sendable {
    public let items: [ShelfItem]
    public let item: ShelfItem?
    public let removed: [ShelfItem]

    public init(items: [ShelfItem], item: ShelfItem? = nil, removed: [ShelfItem] = []) {
        self.items = items
        self.item = item
        self.removed = removed
    }
}

public struct ShelfPositionUpdateResult: Equatable, Sendable {
    public let items: [ShelfItem]
    public let changed: Bool

    public init(items: [ShelfItem], changed: Bool) {
        self.items = items
        self.changed = changed
    }
}

public enum ShelfMutationError: LocalizedError, Equatable {
    case sourceMissing(String)
    case itemMissing(UUID)
    case indexUnreadable(String)
    case rootUnavailable(String)
    case lockUnavailable(String)
    case recoveryFailed(String)

    public var errorDescription: String? {
        switch self {
        case .sourceMissing(let path): return "no file at \(path)"
        case .itemMissing(let id): return "no shelf item with id \(id.uuidString)"
        case .indexUnreadable(let path): return "the shelf index at \(path) is unreadable"
        case .rootUnavailable(let path): return "the shelf root at \(path) is unavailable"
        case .lockUnavailable(let path): return "the shelf lock at \(path) is unavailable"
        case .recoveryFailed(let path): return "the shelf transaction at \(path) could not recover"
        }
    }
}

struct ShelfFileSystemHooks {
    let synchronizeDirectory: (Int32, URL) -> Bool
    let beforePromisedDirectoryIsolation: () throws -> Void

    init(
        synchronizeDirectory: @escaping (Int32, URL) -> Bool = { descriptor, _ in
            fsync(descriptor) == 0
        },
        beforePromisedDirectoryIsolation: @escaping () throws -> Void = {}
    ) {
        self.synchronizeDirectory = synchronizeDirectory
        self.beforePromisedDirectoryIsolation = beforePromisedDirectoryIsolation
    }

    static let live = ShelfFileSystemHooks()
}

private enum ShelfWriteDurability {
    case confirmed
    case uncertain
}

fileprivate final class ShelfDirectory {
    let descriptor: Int32
    let logicalURL: URL
    private let fileSystem: ShelfFileSystemHooks

    init(
        opening url: URL, fileManager: FileManager,
        fileSystem: ShelfFileSystemHooks = .live
    ) throws {
        if fileManager.fileExists(atPath: url.path), !Self.realDirectory(url) {
            throw ShelfMutationError.rootUnavailable(url.path)
        }
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw ShelfMutationError.rootUnavailable(url.path) }
        self.descriptor = descriptor
        logicalURL = url
        self.fileSystem = fileSystem
    }

    init(descriptor: Int32, logicalURL: URL, fileSystem: ShelfFileSystemHooks) {
        self.descriptor = descriptor
        self.logicalURL = logicalURL
        self.fileSystem = fileSystem
    }

    deinit { close(descriptor) }

    func openDirectory(_ name: String) throws -> ShelfDirectory {
        let child = openat(descriptor, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard child >= 0 else {
            throw ShelfMutationError.recoveryFailed(logicalURL.appendingPathComponent(name).path)
        }
        return ShelfDirectory(
            descriptor: child, logicalURL: logicalURL.appendingPathComponent(name),
            fileSystem: fileSystem)
    }

    func createDirectory(_ name: String) throws -> ShelfDirectory {
        guard mkdirat(descriptor, name, 0o700) == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
        return try openDirectory(name)
    }

    func contains(_ name: String) -> Bool {
        var status = stat()
        return fstatat(descriptor, name, &status, AT_SYMLINK_NOFOLLOW) == 0
    }

    func names() throws -> [String] {
        let listing = openat(descriptor, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard listing >= 0, let directory = fdopendir(listing) else {
            if listing >= 0 { close(listing) }
            throw CocoaError(.fileReadUnknown)
        }
        defer { closedir(directory) }
        var result: [String] = []
        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(cString: $0)
                }
            }
            if name != ".", name != ".." { result.append(name) }
        }
        return result
    }

    func read(_ name: String) throws -> Data {
        let file = openat(descriptor, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard file >= 0 else { throw CocoaError(.fileReadNoSuchFile) }
        let handle = FileHandle(fileDescriptor: file, closeOnDealloc: true)
        return try handle.readToEnd() ?? Data()
    }

    func write(_ data: Data, atomicallyTo name: String) throws -> ShelfWriteDurability {
        let temporary = ".temporary-\(UUID().uuidString)"
        let file = openat(
            descriptor, temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard file >= 0 else { throw CocoaError(.fileWriteUnknown) }
        var fileIsOpen = true
        do {
            let handle = FileHandle(fileDescriptor: file, closeOnDealloc: true)
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
            fileIsOpen = false
            guard renameat(descriptor, temporary, descriptor, name) == 0 else {
                throw CocoaError(.fileWriteUnknown)
            }
            return fileSystem.synchronizeDirectory(descriptor, logicalURL)
                ? .confirmed : .uncertain
        } catch {
            if fileIsOpen { close(file) }
            _ = unlinkat(descriptor, temporary, 0)
            throw error
        }
    }

    func move(_ name: String, to directory: ShelfDirectory, as destination: String) throws {
        guard renameat(descriptor, name, directory.descriptor, destination) == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    func remove(_ name: String) throws {
        var status = stat()
        guard fstatat(descriptor, name, &status, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return }
            throw CocoaError(.fileWriteUnknown)
        }
        if status.st_mode & S_IFMT == S_IFDIR {
            let child = try openDirectory(name)
            for entry in try child.names() { try child.remove(entry) }
            guard unlinkat(descriptor, name, AT_REMOVEDIR) == 0 else {
                throw CocoaError(.fileWriteUnknown)
            }
        } else {
            guard unlinkat(descriptor, name, 0) == 0 else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        try synchronize()
    }

    func removeEmptyDirectory(_ name: String, matching expected: ShelfDirectory) throws -> Bool {
        try fileSystem.beforePromisedDirectoryIsolation()
        let isolated = ".edith-shelf-discard-\(UUID().uuidString)"
        guard
            renameatx_np(
                descriptor, name, descriptor, isolated, UInt32(RENAME_EXCL)) == 0
        else {
            if errno == ENOENT { return false }
            throw CocoaError(.fileWriteUnknown)
        }
        var expectedStatus = stat()
        guard fstat(expected.descriptor, &expectedStatus) == 0 else {
            throw CocoaError(.fileReadUnknown)
        }
        var isolatedStatus = stat()
        guard fstatat(descriptor, isolated, &isolatedStatus, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
        guard isolatedStatus.st_mode & S_IFMT == S_IFDIR,
            isolatedStatus.st_dev == expectedStatus.st_dev,
            isolatedStatus.st_ino == expectedStatus.st_ino
        else {
            guard
                renameatx_np(
                    descriptor, isolated, descriptor, name, UInt32(RENAME_EXCL)) == 0
            else {
                try synchronize()
                throw CocoaError(.fileWriteUnknown)
            }
            try synchronize()
            return false
        }
        guard unlinkat(descriptor, isolated, AT_REMOVEDIR) == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
        try synchronize()
        return true
    }

    func synchronize() throws {
        guard fileSystem.synchronizeDirectory(descriptor, logicalURL) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    func copy(_ source: URL, to name: String, fileManager: FileManager) throws {
        let values = try source.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        if values.isSymbolicLink == true {
            let target = try fileManager.destinationOfSymbolicLink(atPath: source.path)
            guard symlinkat(target, descriptor, name) == 0 else {
                throw CocoaError(.fileWriteUnknown)
            }
            try synchronize()
            return
        }
        if values.isDirectory == true {
            let child = try createDirectory(name)
            do {
                for entry in try fileManager.contentsOfDirectory(
                    at: source, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                {
                    try child.copy(entry, to: entry.lastPathComponent, fileManager: fileManager)
                }
                try child.synchronize()
                try synchronize()
            } catch {
                try? remove(name)
                throw error
            }
            return
        }
        let sourceDescriptor = open(source.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard sourceDescriptor >= 0 else { throw ShelfMutationError.sourceMissing(source.path) }
        defer { close(sourceDescriptor) }
        let destination = openat(
            descriptor, name, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard destination >= 0 else { throw CocoaError(.fileWriteUnknown) }
        do {
            guard fcopyfile(sourceDescriptor, destination, nil, copyfile_flags_t(COPYFILE_ALL)) == 0
            else { throw CocoaError(.fileWriteUnknown) }
            guard fsync(destination) == 0 else { throw CocoaError(.fileWriteUnknown) }
            try synchronize()
            close(destination)
        } catch {
            close(destination)
            _ = unlinkat(descriptor, name, 0)
            throw error
        }
    }

    func copy(_ name: String, to destination: ShelfDirectory, as destinationName: String) throws {
        var status = stat()
        guard fstatat(descriptor, name, &status, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        if status.st_mode & S_IFMT == S_IFLNK {
            var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            let count = readlinkat(descriptor, name, &buffer, buffer.count - 1)
            guard count >= 0 else { throw CocoaError(.fileReadUnknown) }
            buffer[Int(count)] = 0
            guard symlinkat(buffer, destination.descriptor, destinationName) == 0 else {
                throw CocoaError(.fileWriteUnknown)
            }
            try destination.synchronize()
            return
        }
        if status.st_mode & S_IFMT == S_IFDIR {
            let sourceDirectory = try openDirectory(name)
            let destinationDirectory = try destination.createDirectory(destinationName)
            do {
                for entry in try sourceDirectory.names() {
                    try sourceDirectory.copy(entry, to: destinationDirectory, as: entry)
                }
                try destinationDirectory.synchronize()
                try destination.synchronize()
            } catch {
                try? destination.remove(destinationName)
                throw error
            }
            return
        }
        let source = openat(descriptor, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard source >= 0 else { throw CocoaError(.fileReadUnknown) }
        defer { close(source) }
        let target = openat(
            destination.descriptor, destinationName,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard target >= 0 else { throw CocoaError(.fileWriteUnknown) }
        do {
            guard fcopyfile(source, target, nil, copyfile_flags_t(COPYFILE_ALL)) == 0 else {
                throw CocoaError(.fileWriteUnknown)
            }
            guard fsync(target) == 0 else { throw CocoaError(.fileWriteUnknown) }
            try destination.synchronize()
            close(target)
        } catch {
            close(target)
            try? destination.remove(destinationName)
            throw error
        }
    }

    func currentURL() throws -> URL {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(descriptor, F_GETPATH, &buffer) == 0 else {
            throw ShelfMutationError.rootUnavailable(logicalURL.path)
        }
        return URL(fileURLWithPath: String(cString: buffer), isDirectory: true)
    }

    private static func realDirectory(_ url: URL) -> Bool {
        guard
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        else { return false }
        return values.isDirectory == true && values.isSymbolicLink != true
    }
}

fileprivate final class ShelfLock {
    private let descriptor: Int32

    init(directory: ShelfDirectory) throws {
        let lock = directory.logicalURL.appendingPathComponent(".index.lock")
        var descriptor: Int32 = -1
        var attempt = 0
        var lockError: Int32 = 0
        repeat {
            descriptor = openat(
                directory.descriptor, ".index.lock",
                O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
            lockError = errno
            attempt += 1
            if descriptor < 0, lockError == ENOENT || lockError == EINTR { sched_yield() }
        } while descriptor < 0 && (lockError == ENOENT || lockError == EINTR) && attempt < 16
        guard descriptor >= 0 else {
            throw ShelfMutationError.lockUnavailable(
                "\(lock.path): \(String(cString: strerror(lockError)))")
        }
        guard flock(descriptor, LOCK_EX) == 0 else {
            close(descriptor)
            throw ShelfMutationError.lockUnavailable(lock.path)
        }
        self.descriptor = descriptor
    }

    deinit {
        _ = flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}

public final class ShelfPinnedSelection: @unchecked Sendable {
    public let items: [ShelfItem]
    private let directory: ShelfDirectory
    private let lock: ShelfLock

    fileprivate init(items: [ShelfItem], directory: ShelfDirectory, lock: ShelfLock) {
        self.items = items
        self.directory = directory
        self.lock = lock
    }

    public func fileURLs(for itemIDs: [UUID]) throws -> [URL] {
        let indexed = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        let selected = try itemIDs.map { id in
            guard let item = indexed[id] else { throw ShelfMutationError.itemMissing(id) }
            guard directory.contains(item.name) else {
                throw ShelfMutationError.sourceMissing(item.name)
            }
            return item
        }
        let root = try directory.currentURL()
        return selected.map { root.appendingPathComponent($0.name) }
    }

    public func stagedFiles(for itemIDs: [UUID]) throws -> ShelfStagedFiles {
        let indexed = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        let selected = try itemIDs.map { id in
            guard let item = indexed[id] else { throw ShelfMutationError.itemMissing(id) }
            guard directory.contains(item.name) else {
                throw ShelfMutationError.sourceMissing(item.name)
            }
            return item
        }
        return try ShelfStagedFiles(items: selected, source: directory)
    }
}

public final class ShelfStagedFiles: @unchecked Sendable {
    public let urls: [URL]
    private let staging: ShelfIncomingDirectory

    fileprivate init(items: [ShelfItem], source: ShelfDirectory) throws {
        let staging = try ShelfIncomingDirectory()
        for item in items {
            try source.copy(item.name, to: staging.directory, as: item.name)
        }
        self.staging = staging
        urls = items.map { staging.url.appendingPathComponent($0.name) }
    }
}

public final class ShelfIncomingDirectory: @unchecked Sendable {
    fileprivate let directory: ShelfDirectory
    private let fileSystem: ShelfFileSystemHooks
    public let url: URL

    public convenience init() throws {
        try self.init(fileSystem: .live)
    }

    init(fileSystem: ShelfFileSystemHooks) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "edith-shelf-incoming-\(UUID().uuidString)")
        directory = try ShelfDirectory(
            opening: root, fileManager: .default, fileSystem: fileSystem)
        self.fileSystem = fileSystem
        url = try directory.currentURL()
    }

    deinit { try? discard() }

    public func discard() throws {
        for _ in 0..<3 {
            let currentURL = try directory.currentURL()
            for name in try directory.names() { try directory.remove(name) }
            let parentURL = currentURL.deletingLastPathComponent()
            let parent = try ShelfDirectory(
                opening: parentURL, fileManager: .default, fileSystem: fileSystem)
            if try parent.removeEmptyDirectory(
                currentURL.lastPathComponent, matching: directory)
            {
                return
            }
        }
        throw CocoaError(.fileWriteUnknown)
    }

    fileprivate func copy(_ source: URL, to destination: ShelfDirectory, as name: String) throws {
        let parent = source.deletingLastPathComponent().standardizedFileURL
        guard parent == url.standardizedFileURL else { throw CocoaError(.fileReadInvalidFileName) }
        try directory.copy(source.lastPathComponent, to: destination, as: name)
    }
}

public enum ShelfMutationExecution {
    private static let legacyIndexName = "index.json"
    private static let lockName = ".index.lock"
    private static let removalPrefix = ".removing-"
    private static let removalPreparationPrefix = ".preparing-removal-"
    private static let removalQuarantinePrefix = ".quarantined-removal-"
    private static let incomingPrefix = ".incoming-"
    private static let transactionName = ".items.json"

    public static func uniqueName(
        _ proposed: String, root: URL = ShelfIndex.root,
        fileManager: FileManager = .default
    ) -> String {
        uniqueName(proposed, reserved: [], root: root, fileManager: fileManager)
    }

    private static func uniqueName(
        _ proposed: String, reserved: Set<String>, root: URL,
        fileManager: FileManager
    ) -> String {
        let candidate = validItemName(proposed) ? proposed : replacementName(for: proposed)
        var name = candidate
        var counter = 2
        let base = (candidate as NSString).deletingPathExtension
        let ext = (candidate as NSString).pathExtension
        while reserved.contains(name) || !validItemName(name)
            || fileManager.fileExists(atPath: root.appendingPathComponent(name).path)
        {
            name = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
            counter += 1
        }
        return name
    }

    private static func uniqueName(
        _ proposed: String, reserved: Set<String> = [], root: ShelfDirectory
    ) -> String {
        let candidate = validItemName(proposed) ? proposed : replacementName(for: proposed)
        var name = candidate
        var counter = 2
        let base = (candidate as NSString).deletingPathExtension
        let ext = (candidate as NSString).pathExtension
        while reserved.contains(name) || !validItemName(name) || root.contains(name) {
            name = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
            counter += 1
        }
        return name
    }

    public static func snapshot(
        root: URL = ShelfIndex.root, fileManager: FileManager = .default
    ) throws -> ShelfMutationResult {
        try withLock(root: root, fileManager: fileManager) { directory in
            ShelfMutationResult(items: try load(root: directory))
        }
    }

    public static func pinnedSelection(
        root: URL = ShelfIndex.root, fileManager: FileManager = .default
    ) throws -> ShelfPinnedSelection {
        let locked = try lockedRoot(root: root, fileManager: fileManager)
        return ShelfPinnedSelection(
            items: try load(root: locked.directory), directory: locked.directory,
            lock: locked.lock)
    }

    static func pinnedSelection(
        root: URL, fileManager: FileManager = .default, afterOpeningRoot: () throws -> Void
    ) throws -> ShelfPinnedSelection {
        let locked = try lockedRoot(
            root: root, fileManager: fileManager, afterOpeningRoot: afterOpeningRoot)
        return ShelfPinnedSelection(
            items: try load(root: locked.directory), directory: locked.directory,
            lock: locked.lock)
    }

    static func snapshot(
        root: URL, fileManager: FileManager = .default, afterOpeningRoot: () throws -> Void
    ) throws -> ShelfMutationResult {
        try withLock(
            root: root, fileManager: fileManager, afterOpeningRoot: afterOpeningRoot
        ) { directory in
            ShelfMutationResult(items: try load(root: directory))
        }
    }

    public static func addCopy(
        of source: URL, root: URL = ShelfIndex.root, id: UUID = UUID(), addedAt: Date = Date(),
        sender: String, fileManager: FileManager = .default
    ) throws -> ShelfMutationResult {
        try addCopy(
            of: source, root: root, id: id, addedAt: addedAt, sender: sender,
            fileManager: fileManager, fileSystem: .live)
    }

    static func addCopy(
        of source: URL, root: URL, id: UUID = UUID(), addedAt: Date = Date(), sender: String,
        fileManager: FileManager = .default, fileSystem: ShelfFileSystemHooks
    ) throws -> ShelfMutationResult {
        guard fileManager.fileExists(atPath: source.path) else {
            throw ShelfMutationError.sourceMissing(source.path)
        }
        let result = try withLock(
            root: root, fileManager: fileManager, fileSystem: fileSystem
        ) { directory in
            let existing = try load(root: directory)
            let name = uniqueName(
                source.lastPathComponent, reserved: Set(existing.map(\.name)), root: directory)
            try directory.copy(source, to: name, fileManager: fileManager)
            let item = ShelfItem(id: id, name: name, addedAt: addedAt)
            let items = existing + [item]
            do {
                _ = try save(items, root: directory)
            } catch {
                try? directory.remove(name)
                throw error
            }
            return ShelfMutationResult(items: items, item: item)
        }
        announce(sender)
        return result
    }

    public static func addText(
        _ text: String, root: URL = ShelfIndex.root, id: UUID = UUID(), addedAt: Date = Date(),
        sender: String, fileManager: FileManager = .default
    ) throws -> ShelfMutationResult {
        try addText(
            text, root: root, id: id, addedAt: addedAt, sender: sender,
            fileManager: fileManager, fileSystem: .live)
    }

    static func addText(
        _ text: String, root: URL, id: UUID = UUID(), addedAt: Date = Date(), sender: String,
        fileManager: FileManager = .default, fileSystem: ShelfFileSystemHooks
    ) throws -> ShelfMutationResult {
        let result = try withLock(
            root: root, fileManager: fileManager, fileSystem: fileSystem
        ) { directory in
            let existing = try load(root: directory)
            let name = uniqueName(
                "Dropped Text.txt", reserved: Set(existing.map(\.name)), root: directory)
            guard try directory.write(Data(text.utf8), atomicallyTo: name) == .confirmed else {
                try? directory.remove(name)
                throw CocoaError(.fileWriteUnknown)
            }
            let item = ShelfItem(id: id, name: name, addedAt: addedAt)
            let items = existing + [item]
            do {
                _ = try save(items, root: directory)
            } catch {
                try? directory.remove(name)
                throw error
            }
            return ShelfMutationResult(items: items, item: item)
        }
        announce(sender)
        return result
    }

    public static func adopt(
        fileAt source: URL, root: URL = ShelfIndex.root, id: UUID, addedAt: Date = Date(),
        incoming: ShelfIncomingDirectory? = nil, sender: String,
        fileManager: FileManager = .default
    ) throws -> ShelfMutationResult {
        let result = try withLock(root: root, fileManager: fileManager) { directory in
            let existing = try load(root: directory)
            let name = uniqueName(
                source.lastPathComponent, reserved: Set(existing.map(\.name)), root: directory)
            if let incoming {
                try incoming.copy(source, to: directory, as: name)
            } else {
                try directory.copy(source, to: name, fileManager: fileManager)
            }
            let item = ShelfItem(id: id, name: name, addedAt: addedAt)
            let items = existing + [item]
            do {
                _ = try save(items, root: directory)
            } catch {
                try? directory.remove(name)
                throw error
            }
            if incoming == nil { try? fileManager.removeItem(at: source) }
            return ShelfMutationResult(items: items, item: item)
        }
        announce(sender)
        return result
    }

    public static func remove(
        id: UUID, root: URL = ShelfIndex.root, sender: String,
        fileManager: FileManager = .default
    ) throws -> ShelfMutationResult {
        try remove(ids: [id], root: root, sender: sender, fileManager: fileManager)
    }

    public static func updatePositions(
        _ positions: [UUID: CGPoint], root: URL = ShelfIndex.root, sender: String,
        fileManager: FileManager = .default
    ) throws -> ShelfPositionUpdateResult {
        let result = try withLock(root: root, fileManager: fileManager) { directory in
            var items = try load(root: directory)
            let known = Set(items.map(\.id))
            if let missing = positions.keys.first(where: { !known.contains($0) }) {
                throw ShelfMutationError.itemMissing(missing)
            }
            var changed = false
            for index in items.indices {
                guard let position = positions[items[index].id] else { continue }
                changed = changed || items[index].position != position
                items[index].position = position
            }
            guard changed else { return ShelfPositionUpdateResult(items: items, changed: false) }
            _ = try save(items, root: directory)
            return ShelfPositionUpdateResult(items: items, changed: true)
        }
        if result.changed { announce(sender) }
        return result
    }

    public static func remove(
        ids: Set<UUID>, root: URL = ShelfIndex.root, sender: String,
        fileManager: FileManager = .default
    ) throws -> ShelfMutationResult {
        try remove(
            ids: ids, root: root, sender: sender, fileManager: fileManager, fileSystem: .live)
    }

    static func remove(
        ids: Set<UUID>, root: URL, sender: String, fileManager: FileManager = .default,
        fileSystem: ShelfFileSystemHooks
    ) throws -> ShelfMutationResult {
        let result = try withLock(
            root: root, fileManager: fileManager, fileSystem: fileSystem
        ) { directory in
            let items = try load(root: directory)
            let known = Set(items.map(\.id))
            if let missing = ids.first(where: { !known.contains($0) }) {
                throw ShelfMutationError.itemMissing(missing)
            }
            guard !ids.isEmpty else { return ShelfMutationResult(items: items) }
            let removed = items.filter { ids.contains($0.id) }
            let kept = items.filter { !ids.contains($0.id) }
            try removeLocked(removed: removed, kept: kept, root: directory)
            return ShelfMutationResult(items: kept, removed: removed)
        }
        if !result.removed.isEmpty { announce(sender) }
        return result
    }

    public static func clear(
        root: URL = ShelfIndex.root, sender: String, fileManager: FileManager = .default
    ) throws -> ShelfMutationResult {
        try clear(
            root: root, sender: sender, fileManager: fileManager, afterOpeningRoot: {})
    }

    static func clear(
        root: URL, sender: String, fileManager: FileManager = .default,
        afterOpeningRoot: () throws -> Void
    ) throws -> ShelfMutationResult {
        let result = try withLock(
            root: root, fileManager: fileManager, afterOpeningRoot: afterOpeningRoot
        ) { directory in
            let items = try load(root: directory)
            guard !items.isEmpty else { return ShelfMutationResult(items: []) }
            try removeLocked(removed: items, kept: [], root: directory)
            return ShelfMutationResult(items: [], removed: items)
        }
        if !result.removed.isEmpty { announce(sender) }
        return result
    }

    public static func purgeExpired(
        keep: ShelfKeepDuration, now: Date = Date(), root: URL = ShelfIndex.root,
        sender: String, fileManager: FileManager = .default
    ) throws -> ShelfMutationResult {
        let result = try withLock(root: root, fileManager: fileManager) { directory in
            let items = try load(root: directory)
            let expired = items.filter {
                ShelfExpiry.isExpired(addedAt: $0.addedAt, keep: keep, now: now)
            }
            guard !expired.isEmpty else { return ShelfMutationResult(items: items) }
            let expiredIDs = Set(expired.map(\.id))
            let kept = items.filter { !expiredIDs.contains($0.id) }
            try removeLocked(removed: expired, kept: kept, root: directory)
            return ShelfMutationResult(items: kept, removed: expired)
        }
        guard !result.removed.isEmpty else { return result }
        announce(sender)
        return result
    }

    private static func withLock<T>(
        root: URL, fileManager: FileManager, afterOpeningRoot: () throws -> Void = {},
        fileSystem: ShelfFileSystemHooks = .live,
        _ body: (ShelfDirectory) throws -> T
    ) throws -> T {
        let locked = try lockedRoot(
            root: root, fileManager: fileManager, afterOpeningRoot: afterOpeningRoot,
            fileSystem: fileSystem)
        return try withExtendedLifetime(locked.lock) { try body(locked.directory) }
    }

    private static func lockedRoot(
        root: URL, fileManager: FileManager, afterOpeningRoot: () throws -> Void = {},
        fileSystem: ShelfFileSystemHooks = .live
    ) throws -> (directory: ShelfDirectory, lock: ShelfLock) {
        let directory = try ShelfDirectory(
            opening: root, fileManager: fileManager, fileSystem: fileSystem)
        try afterOpeningRoot()
        let lock = try ShelfLock(directory: directory)
        try migrateLegacyIndexLocked(root: directory)
        try quarantineRemovalPreparationsLocked(root: directory)
        try recoverRemovalTransactionsLocked(root: directory)
        try migrateLegacyFoldersLocked(root: directory)
        return (directory, lock)
    }

    private static func load(root: ShelfDirectory) throws -> [ShelfItem] {
        let indexName = ShelfIndex.indexFile().lastPathComponent
        guard root.contains(indexName) else { return [] }
        do {
            let items = try JSONDecoder().decode([ShelfItem].self, from: root.read(indexName))
            try validate(items, path: root.logicalURL.appendingPathComponent(indexName).path)
            return items
        } catch {
            throw ShelfMutationError.indexUnreadable(
                root.logicalURL.appendingPathComponent(indexName).path)
        }
    }

    private static func removeLocked(
        removed: [ShelfItem], kept: [ShelfItem], root: ShelfDirectory
    ) throws {
        let transactionID = UUID().uuidString
        let preparationName = "\(removalPreparationPrefix)\(transactionID)"
        let stagingName = "\(removalPrefix)\(transactionID)"
        let preparation = try root.createDirectory(preparationName)
        do {
            guard
                try preparation.write(
                    JSONEncoder().encode(removed), atomicallyTo: transactionName) == .confirmed
            else { throw CocoaError(.fileWriteUnknown) }
            try root.move(preparationName, to: root, as: stagingName)
            try root.synchronize()
        } catch {
            try? root.remove(preparationName)
            throw error
        }
        let staging = try root.openDirectory(stagingName)
        do {
            for item in removed {
                guard root.contains(item.name) else { continue }
                try root.move(item.name, to: staging, as: item.id.uuidString)
            }
            try root.synchronize()
            try staging.synchronize()
            _ = try save(kept, root: root)
        } catch {
            do {
                try rollbackRemovalTransaction(staging: staging, removed: removed, root: root)
            } catch {
                throw ShelfMutationError.recoveryFailed(staging.logicalURL.path)
            }
            throw error
        }
        try? root.remove(stagingName)
    }

    private static func migrateLegacyIndexLocked(root: ShelfDirectory) throws {
        let indexName = ShelfIndex.indexFile().lastPathComponent
        guard root.contains(legacyIndexName), !root.contains(indexName)
        else { return }
        try root.move(legacyIndexName, to: root, as: indexName)
    }

    private static func migrateLegacyFoldersLocked(root: ShelfDirectory) throws {
        var items = try load(root: root)
        var moved: [(directory: ShelfDirectory, legacy: String, destination: String)] = []
        for index in items.indices {
            let directoryName = items[index].id.uuidString
            guard root.contains(directoryName) else { continue }
            let directory = try root.openDirectory(directoryName)
            let legacy = items[index].name
            guard directory.contains(legacy) else { continue }
            let name = uniqueName(items[index].name, root: root)
            do {
                try directory.move(legacy, to: root, as: name)
            } catch {
                try rollbackLegacyMoves(moved, root: root)
                throw error
            }
            moved.append((directory, legacy, name))
            items[index] = ShelfItem(
                id: items[index].id, name: name, addedAt: items[index].addedAt,
                position: items[index].position)
        }
        guard !moved.isEmpty else { return }
        do {
            _ = try save(items, root: root)
        } catch {
            try rollbackLegacyMoves(moved, root: root)
            throw error
        }
        for entry in moved {
            try? root.remove(entry.directory.logicalURL.lastPathComponent)
        }
    }

    private static func rollbackLegacyMoves(
        _ moved: [(directory: ShelfDirectory, legacy: String, destination: String)],
        root: ShelfDirectory
    ) throws {
        for entry in moved.reversed() {
            try root.move(entry.destination, to: entry.directory, as: entry.legacy)
        }
    }

    private static func recoverRemovalTransactionsLocked(root: ShelfDirectory) throws {
        let entries = try root.names().filter { $0.hasPrefix(removalPrefix) }
        for stagingName in entries {
            let staging = try root.openDirectory(stagingName)
            let removed: [ShelfItem]
            do {
                removed = try JSONDecoder().decode(
                    [ShelfItem].self, from: staging.read(transactionName))
                try validate(removed, path: staging.logicalURL.path)
            } catch {
                do {
                    try quarantineRemovalTransaction(stagingName, root: root)
                } catch {
                    throw ShelfMutationError.recoveryFailed(staging.logicalURL.path)
                }
                continue
            }
            let indexExists = root.contains(ShelfIndex.indexFile().lastPathComponent)
            let indexed = try load(root: root)
            let indexedIDs = Set(indexed.map(\.id))
            if !indexExists || removed.contains(where: { indexedIDs.contains($0.id) }) {
                do {
                    try rollbackRemovalTransaction(staging: staging, removed: removed, root: root)
                } catch {
                    throw ShelfMutationError.recoveryFailed(staging.logicalURL.path)
                }
            } else {
                do {
                    try root.remove(stagingName)
                } catch {
                    throw ShelfMutationError.recoveryFailed(staging.logicalURL.path)
                }
            }
        }
    }

    private static func quarantineRemovalPreparationsLocked(root: ShelfDirectory) throws {
        let entries = try root.names().filter { $0.hasPrefix(removalPreparationPrefix) }
        for name in entries { try quarantineRemovalTransaction(name, root: root) }
    }

    private static func quarantineRemovalTransaction(_ name: String, root: ShelfDirectory) throws {
        let suffix: Substring
        if name.hasPrefix(removalPrefix) {
            suffix = name.dropFirst(removalPrefix.count)
        } else {
            suffix = name.dropFirst(removalPreparationPrefix.count)
        }
        var quarantineName = "\(removalQuarantinePrefix)\(suffix)"
        while root.contains(quarantineName) {
            quarantineName = "\(removalQuarantinePrefix)\(UUID().uuidString)"
        }
        try root.move(name, to: root, as: quarantineName)
        try root.synchronize()
    }

    private static func rollbackRemovalTransaction(
        staging: ShelfDirectory, removed: [ShelfItem], root: ShelfDirectory
    ) throws {
        for item in removed.reversed() {
            let staged = item.id.uuidString
            guard staging.contains(staged) else { continue }
            guard !root.contains(item.name) else {
                throw ShelfMutationError.recoveryFailed(staging.logicalURL.path)
            }
            try staging.move(staged, to: root, as: item.name)
        }
        try staging.synchronize()
        try root.synchronize()
        try root.remove(staging.logicalURL.lastPathComponent)
    }

    private static func validate(_ items: [ShelfItem], path: String) throws {
        let ids = Set(items.map(\.id))
        let names = Set(items.map(\.name))
        guard ids.count == items.count, names.count == items.count,
            items.allSatisfy({ validItemName($0.name) })
        else { throw ShelfMutationError.indexUnreadable(path) }
    }

    private static func validItemName(_ name: String) -> Bool {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("\0"),
            (name as NSString).lastPathComponent == name
        else { return false }
        return name != legacyIndexName && name != lockName
            && name != ShelfIndex.indexFile().lastPathComponent
            && !name.hasPrefix(removalPrefix) && !name.hasPrefix(removalPreparationPrefix)
            && !name.hasPrefix(removalQuarantinePrefix) && !name.hasPrefix(incomingPrefix)
    }

    private static func replacementName(for proposed: String) -> String {
        let ext = (proposed as NSString).pathExtension
        return ext.isEmpty ? "Shelf Item" : "Shelf Item.\(ext)"
    }

    private static func save(
        _ items: [ShelfItem], root: ShelfDirectory
    ) throws -> ShelfWriteDurability {
        let data = try JSONEncoder().encode(items)
        return try root.write(data, atomicallyTo: ShelfIndex.indexFile().lastPathComponent)
    }

    private static func announce(_ sender: String) {
        IPC.post(IPC.Name.shelfChanged, userInfo: ["sender": sender])
    }
}
