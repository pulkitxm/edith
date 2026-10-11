import Darwin
import Foundation

public enum ExtensionCommandOwnership {
    public static let registerNotification = Notification.Name(
        "edith.extension.registerProcessGroup")
    public static let releaseNotification = Notification.Name("edith.extension.releaseProcessGroup")
    public static var isWorker: Bool {
        ProcessInfo.processInfo.environment["EDITH_EXTENSION_WORKER"] == "1"
    }

    public static func captureGroup(pid: Int32) throws -> ExtensionOwnedProcessGroup {
        guard let birth = ExtensionProcessIdentity.read(pid),
            ExtensionNativeTask.isDescendant(pid, of: getpid())
        else { throw CocoaError(.executableLoad) }
        return try ExtensionOwnedProcessGroup(leader: birth)
    }

    public static func register(_ pid: Int32) throws {
        guard isWorker else { return }
        var accepted = false
        let accept: (Bool) -> Void = { accepted = $0 }
        NotificationCenter.default.post(
            name: registerNotification, object: nil, userInfo: ["pid": pid, "accept": accept])
        guard accepted else { throw CocoaError(.executableLoad) }
    }

    public static func release(_ pid: Int32) {
        guard isWorker else { return }
        NotificationCenter.default.post(
            name: releaseNotification, object: nil, userInfo: ["pid": pid])
    }
}

public final class ExtensionOwnedProcessGroup: @unchecked Sendable {
    public struct SignalAttempt: Codable, Sendable {
        public let target: Int32
        public let signal: Int32
        public let witness: ExtensionProcessIdentity
    }

    public let leader: ExtensionProcessIdentity
    private let lock = NSLock()
    private var births: [ExtensionProcessIdentity]
    private var attempts: [SignalAttempt] = []
    private var groups: Set<Int32>
    private var retirement: Task<Void, Error>?
    private var retiring = false
    private var retired = false
    private let read: @Sendable (Int32) -> ExtensionProcessIdentity?
    private let group: @Sendable (Int32) -> Int32
    private let members: @Sendable (Int32) throws -> [Int32]
    private let descendants: @Sendable (Int32) throws -> [ExtensionProcessIdentity]
    private let exists: @Sendable (Int32) -> Bool
    private let send: @Sendable (Int32, Int32) -> Int32

    public var observedBirths: [ExtensionProcessIdentity] { lock.withLock { births } }
    public var signalAttempts: [SignalAttempt] { lock.withLock { attempts } }
    public var isRetired: Bool { lock.withLock { retired } }

    init(
        leader: ExtensionProcessIdentity,
        read: @escaping @Sendable (Int32) -> ExtensionProcessIdentity? = ExtensionProcessIdentity
            .read,
        group: @escaping @Sendable (Int32) -> Int32 = { getpgid($0) },
        members: @escaping @Sendable (Int32) throws -> [Int32] = ExtensionOwnedProcessGroup.members,
        descendants: @escaping @Sendable (Int32) throws -> [ExtensionProcessIdentity] =
            ExtensionOwnedProcessGroup
            .descendants,
        exists: @escaping @Sendable (Int32) -> Bool = { kill($0, 0) == 0 || errno != ESRCH },
        send: @escaping @Sendable (Int32, Int32) -> Int32 = { kill($0, $1) }
    ) throws {
        guard leader.pid > 1, read(leader.pid) == leader, group(leader.pid) == leader.pid else {
            throw CocoaError(.executableLoad)
        }
        self.leader = leader
        self.read = read
        self.group = group
        self.members = members
        self.descendants = descendants
        self.exists = exists
        self.send = send
        births = [leader]
        groups = [leader.pid]
        _ = try refreshLocked()
        guard read(leader.pid) == leader, group(leader.pid) == leader.pid else {
            throw CocoaError(.executableLoad)
        }
    }

    @discardableResult
    public func refreshObserved() throws -> Bool {
        try lock.withLock { try refreshLocked() }
    }

    private func remember(_ birth: ExtensionProcessIdentity) throws {
        guard births.count < 16_384 else { throw CocoaError(.executableLoad) }
        births.append(birth)
    }

    private func trackGroup(_ value: Int32) throws {
        guard value > 1, value != getpgrp(), !groups.contains(value) else { return }
        guard groups.count < 128 else { throw CocoaError(.executableLoad) }
        groups.insert(value)
    }

    private func refreshLocked() throws -> Bool {
        let alive = births.filter { read($0.pid) == $0 }
        for witness in alive {
            let currentGroup = group(witness.pid)
            try trackGroup(currentGroup)
            for child in try descendants(witness.pid) where !births.contains(child) {
                try remember(child)
                let childGroup = group(child.pid)
                try trackGroup(childGroup)
            }
        }
        var occupied = Set<Int32>()
        for ownedGroup in groups {
            let currentMembers = try members(ownedGroup)
            if !currentMembers.isEmpty { occupied.insert(ownedGroup) }
            if births.contains(where: { read($0.pid) == $0 && group($0.pid) == ownedGroup }) {
                for pid in currentMembers {
                    if let birth = read(pid), !births.contains(birth) { try remember(birth) }
                }
            }
        }
        let observedAlive = births.contains {
            let current = read($0.pid)
            return current == $0 || (current == nil && exists($0.pid))
        }
        groups = occupied
        return !observedAlive && occupied.isEmpty
    }

    public func signal(_ value: Int32 = SIGKILL) throws {
        try lock.withLock {
            guard !retired, value == SIGHUP || value == SIGTERM || value == SIGKILL else {
                throw CocoaError(.executableLoad)
            }
            _ = try refreshLocked()
            for ownedGroup in groups.sorted() {
                if let witness = births.first(where: {
                    read($0.pid) == $0 && group($0.pid) == ownedGroup
                }),
                    read(witness.pid) == witness, group(witness.pid) == ownedGroup
                {
                    guard attempts.count < 65_536 else { throw CocoaError(.executableLoad) }
                    attempts.append(.init(target: -ownedGroup, signal: value, witness: witness))
                    guard send(-ownedGroup, value) == 0 || errno == ESRCH else {
                        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    }
                }
            }
            for witness in births where read(witness.pid) == witness {
                guard read(witness.pid) == witness else { continue }
                guard attempts.count < 65_536 else { throw CocoaError(.executableLoad) }
                attempts.append(.init(target: witness.pid, signal: value, witness: witness))
                guard send(witness.pid, value) == 0 || errno == ESRCH else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            }
        }
    }

    public func waitForQuiescence(timeout: Duration = .seconds(5)) async throws {
        guard timeout > .zero, timeout <= .seconds(30) else { throw CocoaError(.executableLoad) }
        let deadline = ContinuousClock.now + timeout
        while !(try refreshObserved()) {
            guard ContinuousClock.now < deadline else { throw CocoaError(.executableLoad) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    public func retire(
        after join: @escaping @Sendable () async throws -> Void, timeout: Duration = .seconds(5)
    ) async throws {
        let task = lock.withLock { () -> Task<Void, Error> in
            if retired { return Task {} }
            if retiring, let retirement { return retirement }
            retiring = true
            let task = Task {
                defer { self.lock.withLock { self.retiring = false } }
                try await join()
                try await self.waitForQuiescence(timeout: timeout)
                try self.lock.withLock {
                    guard try self.refreshLocked() else { throw CocoaError(.executableLoad) }
                    self.retired = true
                }
                ExtensionCommandOwnership.release(self.leader.pid)
            }
            retirement = task
            return task
        }
        try await task.value
    }

    private static func processIDs(_ type: UInt32, _ value: UInt32) throws -> [Int32] {
        errno = 0
        let size = proc_listpids(type, value, nil, 0)
        guard size >= 0, size != 0 || errno == 0, size <= 4_000_000 else {
            throw CocoaError(.executableLoad)
        }
        var pids = [Int32](repeating: 0, count: Int(size) / MemoryLayout<Int32>.size + 256)
        errno = 0
        let count = pids.withUnsafeMutableBytes {
            proc_listpids(type, value, $0.baseAddress, Int32($0.count))
        }
        guard count >= 0, count != 0 || errno == 0,
            Int(count) < pids.count * MemoryLayout<Int32>.size
        else {
            throw CocoaError(.executableLoad)
        }
        return pids.prefix(Int(count) / MemoryLayout<Int32>.size).filter { $0 > 1 }
    }

    private static func members(_ group: Int32) throws -> [Int32] {
        try processIDs(UInt32(PROC_PGRP_ONLY), UInt32(group))
    }

    private static func descendants(_ owner: Int32) throws -> [ExtensionProcessIdentity] {
        try processIDs(UInt32(PROC_ALL_PIDS), 0).filter {
            ExtensionNativeTask.isDescendant($0, of: owner)
        }.compactMap { ExtensionProcessIdentity.read($0) }
    }
}

public struct ExtensionCommandSpecification: Codable, Sendable {
    public let executable: String
    public let arguments: [String]
    public let environment: [String: String]
    public let directory: String?

    public init(
        executable: String, arguments: [String], environment: [String: String],
        directory: String? = nil
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.directory = directory
    }

    public func write(to handle: FileHandle) throws {
        let data = try JSONEncoder().encode(self)
        guard data.count <= 65_536 else { throw CocoaError(.fileWriteOutOfSpace) }
        var count = UInt32(data.count).bigEndian
        try withUnsafeBytes(of: &count) { try handle.write(contentsOf: Data($0)) }
        try handle.write(contentsOf: data)
    }

    public static func runWrapper() throws -> Never {
        guard ExtensionCommandOwnership.isWorker, getpgrp() == getppid() else {
            throw CocoaError(.executableLoad)
        }
        let handle = FileHandle(fileDescriptor: 3, closeOnDealloc: true)
        let header = try read(4, from: handle)
        let count = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard count > 0, count <= 65_536 else { throw CocoaError(.fileReadCorruptFile) }
        let command = try JSONDecoder().decode(Self.self, from: read(Int(count), from: handle))
        try handle.close()
        guard command.executable.hasPrefix("/"), !command.executable.utf8.contains(0),
            command.arguments.allSatisfy({ !$0.utf8.contains(0) }),
            command.environment.allSatisfy({
                !$0.key.contains("=") && !$0.key.utf8.contains(0) && !$0.value.utf8.contains(0)
            }),
            command.directory.map({ $0.hasPrefix("/") && !$0.utf8.contains(0) }) ?? true,
            setpgid(0, 0) == 0
        else { throw CocoaError(.executableLoad) }
        if let directory = command.directory, chdir(directory) != 0 {
            throw CocoaError(.fileReadNoPermission)
        }
        let arguments = ([command.executable] + command.arguments).map { strdup($0) }
        let environment = command.environment.map { strdup($0.key + "=" + $0.value) }
        defer { for item in arguments + environment { free(item) } }
        guard arguments.allSatisfy({ $0 != nil }), environment.allSatisfy({ $0 != nil }) else {
            throw CocoaError(.executableLoad)
        }
        var argv = arguments + [nil]
        var env = environment + [nil]
        for value in [SIGPIPE, SIGINT, SIGTERM, SIGHUP, SIGQUIT, SIGCHLD] { signal(value, SIG_DFL) }
        _ = command.executable.withCString { path in
            argv.withUnsafeMutableBufferPointer { arguments in
                env.withUnsafeMutableBufferPointer { environment in
                    execve(path, arguments.baseAddress!, environment.baseAddress!)
                }
            }
        }
        throw CocoaError(.executableLoad)
    }

    private static func read(_ count: Int, from handle: FileHandle) throws -> Data {
        var data = Data()
        while data.count < count {
            guard let next = try handle.read(upToCount: count - data.count), !next.isEmpty else {
                throw CocoaError(.fileReadCorruptFile)
            }
            data.append(next)
        }
        return data
    }
}
