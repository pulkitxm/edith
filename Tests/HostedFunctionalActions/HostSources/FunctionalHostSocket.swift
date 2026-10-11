import Darwin
import Foundation

struct FunctionalSocketPeer {
    let birth: FunctionalBirth

    init(descriptor: Int32) throws {
        var pid: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0,
            length == socklen_t(MemoryLayout<Int32>.size),
            getpeereid(descriptor, &uid, &gid) == 0, uid == getuid()
        else { throw FunctionalFailure.invalid("socket peer credentials") }
        birth = try FunctionalBirth.observe(pid)
        guard birth.uid == uid else { throw FunctionalFailure.invalid("socket peer birth") }
    }
}

enum FunctionalSocketWire {
    static func address(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        let bytes = Array(path.utf8) + [UInt8(0)]
        guard path.hasPrefix("/"), bytes.count <= MemoryLayout.size(ofValue: address.sun_path)
        else { throw FunctionalFailure.invalid("owned socket path") }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.copyBytes(from: bytes)
        }
        return address
    }

    static func connect(path: String, deadline: ContinuousClock.Instant) throws -> Int32 {
        var address = try self.address(path)
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw FunctionalFailure.invalid("socket creation") }
        do {
            try configure(descriptor)
            guard fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0 else { throw FunctionalFailure.invalid("socket nonblocking") }
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            if result != 0 {
                guard errno == EINPROGRESS else { throw FunctionalFailure.invalid("owned socket connection") }
                try ready(descriptor, events: Int16(POLLOUT), deadline: deadline)
                var error: Int32 = 0
                var length = socklen_t(MemoryLayout<Int32>.size)
                guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &error, &length) == 0, error == 0
                else { throw FunctionalFailure.invalid("socket connect result") }
            }
            return descriptor
        } catch { close(descriptor); throw error }
    }

    static func configure(_ descriptor: Int32) throws {
        var enabled: Int32 = 1
        guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0,
            setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size)) == 0
        else { throw FunctionalFailure.invalid("socket configuration") }
    }

    static func readFrame(_ descriptor: Int32, deadline: ContinuousClock.Instant) throws -> Data {
        let header = try readExactly(descriptor, count: 4, deadline: deadline)
        let count = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard count > 0, count <= 1_048_576 else { throw FunctionalFailure.invalid("socket frame bound") }
        return try readExactly(descriptor, count: Int(count), deadline: deadline)
    }

    static func writeFrame(_ bytes: Data, descriptor: Int32, deadline: ContinuousClock.Instant) throws {
        guard !bytes.isEmpty, bytes.count <= 1_048_576 else { throw FunctionalFailure.invalid("socket response bound") }
        let count = UInt32(bytes.count)
        let framed = Data([UInt8((count >> 24) & 255), UInt8((count >> 16) & 255), UInt8((count >> 8) & 255), UInt8(count & 255)]) + bytes
        var offset = 0
        while offset < framed.count {
            try ready(descriptor, events: Int16(POLLOUT), deadline: deadline)
            let written = framed.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress!.advanced(by: offset), $0.count - offset) }
            if written < 0 && [EINTR, EAGAIN].contains(errno) { continue }
            guard written > 0 else { throw FunctionalFailure.invalid("socket write") }
            offset += written
        }
    }

    private static func readExactly(_ descriptor: Int32, count: Int, deadline: ContinuousClock.Instant) throws -> Data {
        var bytes = Data(count: count)
        var offset = 0
        while offset < count {
            try ready(descriptor, events: Int16(POLLIN), deadline: deadline)
            let received = bytes.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress!.advanced(by: offset), count - offset) }
            if received < 0 && [EINTR, EAGAIN].contains(errno) { continue }
            guard received > 0 else { throw FunctionalFailure.invalid("socket closed during frame") }
            offset += received
        }
        return bytes
    }

    private static func ready(_ descriptor: Int32, events: Int16, deadline: ContinuousClock.Instant) throws {
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            var state = pollfd(fd: descriptor, events: events, revents: 0)
            let result = poll(&state, 1, 50)
            if result < 0 && errno == EINTR { continue }
            guard result >= 0 else { throw FunctionalFailure.invalid("socket poll") }
            if result > 0 {
                guard state.revents & events != 0, state.revents & Int16(POLLERR | POLLNVAL) == 0
                else { throw FunctionalFailure.invalid("socket poll state") }
                return
            }
        }
        throw FunctionalFailure.timeout("producer rendezvous")
    }
}

@MainActor
final class FunctionalHostSocket {
    private let descriptor: Int32
    private let path: String
    private let inode: ino_t
    private let device: dev_t
    private let source: DispatchSourceRead
    private var requests = 0
    private var stopped = false
    private var listenerCancelled = false
    private var cancellationWaiter: CheckedContinuation<Void, Never>?
    private var failure: Error?
    private var active = Set<Int32>()
    private var tasks: [UUID: Task<Void, Never>] = [:]
    enum Endpoint { case producer, host }

    init(root: FunctionalPinnedPath, endpoint: Endpoint = .producer, receive: @escaping @MainActor (FunctionalSocketPeer, [String: Any]) async throws -> Data) throws {
        try root.requireCurrent()
        let socketPath = root.url.path + (endpoint == .producer ? "/p.sock" : "/h.sock")
        path = socketPath
        var address = try FunctionalSocketWire.address(path)
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        descriptor = listener
        guard listener >= 0 else { throw FunctionalFailure.invalid("producer listener") }
        do {
            try FunctionalSocketWire.configure(listener)
            guard fcntl(listener, F_SETFL, O_NONBLOCK) == 0 else { throw FunctionalFailure.invalid("listener nonblocking") }
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard bound == 0, chmod(socketPath, 0o600) == 0, listen(listener, 8) == 0
            else { throw FunctionalFailure.invalid("producer listener bind") }
            var state = stat()
            guard lstat(socketPath, &state) == 0, state.st_mode & S_IFMT == S_IFSOCK,
                state.st_uid == getuid(), state.st_mode & 0o7777 == 0o600
            else { throw FunctionalFailure.invalid("producer listener ownership") }
            inode = state.st_ino
            device = state.st_dev
        } catch {
            close(listener)
            var state = stat()
            if lstat(socketPath, &state) == 0, state.st_mode & S_IFMT == S_IFSOCK,
                state.st_uid == getuid(), state.st_mode & 0o7777 == 0o600
            { unlink(socketPath) }
            throw error
        }
        source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: .main)
        source.setCancelHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.listenerCancelled = true
                let waiter = self.cancellationWaiter
                self.cancellationWaiter = nil
                waiter?.resume()
            }
        }
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.stopped, self.failure == nil else { return }
                let client = accept(self.descriptor, nil, nil)
                if client < 0 {
                    if ![EINTR, EAGAIN].contains(errno) { self.failure = FunctionalFailure.invalid("producer accept") }
                    return
                }
                guard self.active.count < 8, self.requests < 4096 else {
                    close(client)
                    self.failure = FunctionalFailure.invalid("producer socket limits")
                    self.source.cancel()
                    return
                }
                self.requests += 1
                self.active.insert(client)
                let token = UUID()
                self.tasks[token] = Task { @MainActor [self] in
                    defer { self.active.remove(client); close(client) }
                    do {
                        try root.requireCurrent()
                        try FunctionalSocketWire.configure(client)
                        guard fcntl(client, F_SETFL, O_NONBLOCK) == 0 else { throw FunctionalFailure.invalid("peer nonblocking") }
                        let peer = try FunctionalSocketPeer(descriptor: client)
                        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
                        let request = try FunctionalBytes.object(FunctionalSocketWire.readFrame(client, deadline: deadline))
                        let response = try await receive(peer, request)
                        try Task.checkCancellation()
                        guard ContinuousClock.now < deadline else { throw FunctionalFailure.timeout("source receiver response") }
                        try peer.birth.requireCurrent()
                        try FunctionalSocketWire.writeFrame(response, descriptor: client, deadline: deadline)
                    } catch { self.failure = error; self.source.cancel() }
                }
            }
        }
        source.resume()
    }

    func requireHealthy() throws {
        if let failure { throw failure }
        guard !stopped else { throw FunctionalFailure.invalid("stopped producer listener") }
        var state = stat()
        guard lstat(path, &state) == 0, state.st_ino == inode, state.st_dev == device,
            state.st_mode & S_IFMT == S_IFSOCK, state.st_uid == getuid(), state.st_mode & 0o7777 == 0o600
        else { throw FunctionalFailure.invalid("producer socket replaced") }
    }

    func closeAndJoin() async throws {
        guard !stopped else { throw FunctionalFailure.invalid("listener already retired") }
        stopped = true
        source.cancel()
        if !listenerCancelled {
            await withCheckedContinuation { cancellationWaiter = $0 }
        }
        guard listenerCancelled else { throw FunctionalFailure.invalid("producer listener cancellation did not return") }
        let joined = Array(tasks.values)
        for task in joined { task.cancel() }
        for task in joined { await task.value }
        guard active.isEmpty else { throw FunctionalFailure.invalid("unjoined producer receiver") }
        var state = stat()
        let ownsPath = lstat(path, &state) == 0 && state.st_ino == inode && state.st_dev == device
            && state.st_mode & S_IFMT == S_IFSOCK && state.st_uid == getuid() && state.st_mode & 0o7777 == 0o600
        let closed = close(descriptor) == 0
        guard ownsPath, closed, unlink(path) == 0 else { throw FunctionalFailure.invalid("producer listener cleanup") }
        tasks.removeAll()
        if let failure { throw failure }
    }
}
