import Darwin
import Foundation

public struct HostStorageBytes: Sendable, Equatable {
    public var logical: Int64 = 0
    public var allocated: Int64 = 0
    public var complete = true
    public var exists = false

    public init() {}

    public mutating func include(_ other: Self) {
        let logicalSum = logical.addingReportingOverflow(other.logical)
        let allocatedSum = allocated.addingReportingOverflow(other.allocated)
        logical = logicalSum.overflow ? Int64.max : logicalSum.partialValue
        allocated = allocatedSum.overflow ? Int64.max : allocatedSum.partialValue
        complete = complete && other.complete && !logicalSum.overflow && !allocatedSum.overflow
        exists = exists || other.exists
    }
}

public struct HostStorageScope: Sendable, Identifiable {
    public let id: String
    public let root: URL
    public let expected: Bool

    public init(id: String, root: URL, expected: Bool = false) {
        self.id = id
        self.root = root
        self.expected = expected
    }
}

public struct HostStorageMeasurement: Sendable {
    public let collectedAt: Date
    public let bytes: [String: HostStorageBytes]
    public let issues: [String]

    public var total: HostStorageBytes {
        bytes.values.reduce(into: HostStorageBytes()) { $0.include($1) }
    }
}

public enum HostStorageAccounting {
    public static func scan(
        scopes: [HostStorageScope], maximumEntries: Int = 250_000,
        duration: Duration = .seconds(30),
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) throws -> HostStorageMeasurement {
        try HostStorageAccountingReader(
            scopes: scopes, maximumEntries: max(1, maximumEntries),
            duration: duration, isCancelled: isCancelled
        ).scan()
    }
}

private final class HostStorageAccountingReader {
    private struct Inode: Hashable {
        let device: dev_t
        let number: ino_t
    }

    private let scopes: [HostStorageScope]
    private let maximumEntries: Int
    private let deadline: ContinuousClock.Instant
    private let isCancelled: @Sendable () -> Bool
    private var measured: [String: HostStorageBytes] = [:]
    private var seen: Set<Inode> = []
    private var visited = 0
    private var issues: Set<String> = []

    init(
        scopes: [HostStorageScope], maximumEntries: Int, duration: Duration,
        isCancelled: @escaping @Sendable () -> Bool
    ) {
        self.scopes = scopes.sorted {
            if $0.root.path.count != $1.root.path.count {
                return $0.root.path.count > $1.root.path.count
            }
            return $0.id < $1.id
        }
        self.maximumEntries = maximumEntries
        deadline = ContinuousClock.now.advanced(
            by: min(max(duration, .milliseconds(1)), .seconds(60)))
        self.isCancelled = isCancelled
    }

    func scan() throws -> HostStorageMeasurement {
        guard Set(scopes.map(\.id)).count == scopes.count,
            scopes.allSatisfy({
                $0.root.isFileURL && $0.root.path.hasPrefix("/")
                    && !$0.root.pathComponents.contains("..") && !$0.root.path.contains("\0")
            })
        else { throw CocoaError(.validationMissingMandatoryProperty) }
        for scope in scopes { measured[scope.id] = HostStorageBytes() }
        let roots = scopes.filter { scope in
            !scopes.contains {
                $0.root.path != scope.root.path && contains($0.root.path, scope.root.path)
            }
        }
        var rootPaths: Set<String> = []
        for scope in roots.sorted(by: { $0.root.path < $1.root.path }) {
            try checkCancelled()
            guard rootPaths.insert(scope.root.path).inserted else { continue }
            let descriptor = openSealed(scope.root)
            guard descriptor >= 0 else {
                if errno != ENOENT {
                    partial(
                        scope.root.path, "A storage root is unreadable or uses a symbolic link.")
                }
                continue
            }
            defer { close(descriptor) }
            try walk(descriptor, path: scope.root.path, depth: 0)
        }
        for scope in scopes where scope.expected && measured[scope.id]?.exists != true {
            measured[scope.id]?.complete = false
            issues.insert(
                "An expected app or package directory was not measured. Refresh after installation finishes."
            )
        }
        return HostStorageMeasurement(collectedAt: Date(), bytes: measured, issues: issues.sorted())
    }

    private func contains(_ root: String, _ path: String) -> Bool {
        path == root || path.hasPrefix(root == "/" ? "/" : root + "/")
    }

    private func owner(_ path: String) -> String? {
        scopes.first { contains($0.root.path, path) }?.id
    }

    private func checkCancelled() throws {
        if isCancelled() { throw CancellationError() }
    }

    private func partial(_ path: String, _ message: String) {
        issues.insert(message)
        for scope in scopes where contains(scope.root.path, path) || contains(path, scope.root.path)
        {
            measured[scope.id]?.complete = false
        }
    }

    private func openSealed(_ url: URL) -> Int32 {
        var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { return descriptor }
        let components = url.pathComponents.filter { $0 != "/" }
        for (index, component) in components.enumerated() {
            let type = index == components.count - 1 ? O_NONBLOCK : O_DIRECTORY
            let next = openat(
                descriptor, component, O_RDONLY | type | O_CLOEXEC | O_NOFOLLOW)
            let failure = errno
            close(descriptor)
            guard next >= 0 else { errno = failure; return -1 }
            descriptor = next
        }
        return descriptor
    }

    private func account(_ information: stat, path: String) {
        guard let id = owner(path) else { return }
        measured[id]?.exists = true
        guard seen.insert(Inode(device: information.st_dev, number: information.st_ino)).inserted
        else { return }
        var bytes = HostStorageBytes()
        bytes.exists = true
        bytes.logical = (information.st_mode & S_IFMT) == S_IFREG ? max(0, information.st_size) : 0
        let allocated = Int64(max(0, information.st_blocks)).multipliedReportingOverflow(by: 512)
        bytes.allocated = allocated.overflow ? Int64.max : allocated.partialValue
        bytes.complete = !allocated.overflow
        measured[id]?.include(bytes)
    }

    private func walk(_ descriptor: Int32, path: String, depth: Int) throws {
        try checkCancelled()
        guard visited < maximumEntries, ContinuousClock.now < deadline, depth < 128 else {
            partial(path, "The scan limit was reached. Reported sizes are partial.")
            return
        }
        visited += 1
        var directoryInfo = stat()
        guard fstat(descriptor, &directoryInfo) == 0 else {
            partial(path, "Some storage could not be read. Reported sizes are partial.")
            return
        }
        account(directoryInfo, path: path)
        if (directoryInfo.st_mode & S_IFMT) == S_IFREG { return }
        guard (directoryInfo.st_mode & S_IFMT) == S_IFDIR else {
            partial(path, "A storage root has an unsupported file type.")
            return
        }
        guard let directory = fdopendir(dup(descriptor)) else {
            partial(path, "Some storage could not be read. Reported sizes are partial.")
            return
        }
        defer { closedir(directory) }
        var names: [String] = []
        while true {
            try checkCancelled()
            errno = 0
            guard let entry = readdir(directory) else {
                if errno != 0 {
                    partial(path, "Some storage could not be read. Reported sizes are partial.")
                }
                break
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(cString: $0)
                }
            }
            guard name != ".", name != ".." else { continue }
            guard names.count + visited < maximumEntries, ContinuousClock.now < deadline else {
                partial(path, "The scan limit was reached. Reported sizes are partial.")
                break
            }
            names.append(name)
        }
        for name in names.sorted() {
            try checkCancelled()
            let childPath = path == "/" ? "/" + name : path + "/" + name
            guard visited < maximumEntries, ContinuousClock.now < deadline else {
                partial(path, "The scan limit was reached. Reported sizes are partial.")
                break
            }
            var information = stat()
            guard fstatat(descriptor, name, &information, AT_SYMLINK_NOFOLLOW) == 0 else {
                partial(
                    childPath,
                    "Storage changed or could not be read during the scan. Refresh to try again.")
                continue
            }
            switch information.st_mode & S_IFMT {
            case S_IFDIR:
                let child = openat(
                    descriptor, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
                guard child >= 0 else {
                    partial(
                        childPath,
                        "Storage changed or could not be read during the scan. Refresh to try again."
                    )
                    continue
                }
                defer { close(child) }
                var opened = stat()
                guard fstat(child, &opened) == 0, opened.st_dev == information.st_dev,
                    opened.st_ino == information.st_ino
                else {
                    partial(childPath, "Storage changed during the scan. Refresh to try again.")
                    continue
                }
                try walk(child, path: childPath, depth: depth + 1)
            case S_IFREG:
                visited += 1
                account(information, path: childPath)
            case S_IFLNK:
                visited += 1
                account(information, path: childPath)
                issues.insert(
                    "Symbolic link targets are excluded; allocated blocks for the links themselves are counted."
                )
                for scope in scopes where contains(childPath, scope.root.path) {
                    measured[scope.id]?.complete = false
                }
            default:
                visited += 1
            }
        }
    }
}
