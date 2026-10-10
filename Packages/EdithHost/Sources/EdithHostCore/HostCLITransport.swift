import CryptoKit
import Darwin
import Foundation

@_silgen_name("csops")
private func processCodeSigningOperation(
    _ pid: Int32, _ operation: UInt32,
    _ buffer: UnsafeMutableRawPointer, _ count: Int
) -> Int32

struct HostCLIProcess: Equatable, Sendable {
    let pid: Int32
    let started: UInt64
    let microseconds: UInt64
    let executable: String
    let codeHash: Data

    static func read(_ pid: Int32) -> Self? {
        var info = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.size
        guard pid > 1, proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(size)) == size,
            info.pbi_uid == getuid(), info.pbi_ruid == getuid()
        else { return nil }
        var path = [CChar](repeating: 0, count: 4096)
        var hash = [UInt8](repeating: 0, count: 20)
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0,
            processCodeSigningOperation(pid, 5, &hash, hash.count) == 0,
            hash.contains(where: { $0 != 0 })
        else { return nil }
        return Self(
            pid: pid, started: info.pbi_start_tvsec, microseconds: info.pbi_start_tvusec,
            executable: String(cString: path), codeHash: Data(hash))
    }

    static func peer(_ descriptor: Int32) throws -> Self {
        var uid: uid_t = 0
        var gid: gid_t = 0
        var pid: Int32 = 0
        var size = socklen_t(MemoryLayout<Int32>.size)
        guard getpeereid(descriptor, &uid, &gid) == 0, uid == getuid(),
            getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) == 0,
            let peer = read(pid), let current = read(getpid()),
            peer.executable == current.executable, peer.codeHash == current.codeHash
        else { throw HostCLIError.unavailable }
        return peer
    }
}

struct HostCLIResponse: Codable, Sendable {
    let payload: Data?
    let error: String?
    let exitCode: Int32
}

public enum HostCLITransport {
    static let maximumFrame = 12 * 1024 * 1024
    static let maximumRequest = 1024 * 1024
    static let directory = "/tmp/edith-cli-\(getuid())"

    public static func socketPath(identity: HostIdentity) throws -> String {
        guard let current = HostCLIProcess.read(getpid()) else { throw HostCLIError.unavailable }
        let key = identity.identifier + "\0" + current.executable
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory + "/" + String(digest.prefix(48)) + ".sock"
    }

    static func address(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        guard path.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw HostCLIError.unavailable
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8) + [0]) }
        return address
    }

    static func prepareDirectory() throws {
        if mkdir(directory, 0o700) != 0, errno != EEXIST { throw HostCLIError.unavailable }
        var info = stat()
        guard lstat(directory, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
            info.st_uid == getuid(), info.st_mode & 0o777 == 0o700
        else { throw HostCLIError.unavailable }
    }

    public static func invoke(_ request: HostCLIRequest, identity: HostIdentity) throws -> Data {
        try request.validate()
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw HostCLIError.unavailable }
        let connection = HostCLIConnection(descriptor)
        defer { connection.close() }
        try connection.configure(timeout: request.timeout + 2)
        var address = try address(socketPath(identity: identity))
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { throw HostCLIError.unavailable }
        let peer = try HostCLIProcess.peer(descriptor)
        try connection.write(JSONEncoder().encode(request), limit: maximumRequest)
        let response = try JSONDecoder().decode(
            HostCLIResponse.self,
            from: connection.read(limit: maximumFrame))
        guard HostCLIProcess.read(peer.pid) == peer else { throw HostCLIError.unavailable }
        if let error = response.error {
            if response.exitCode == 4 { throw HostCLIError.timedOut }
            if response.exitCode == 2 { throw HostCLIError.usage(error) }
            throw HostCLIError.rejected(error)
        }
        guard let payload = response.payload, response.exitCode == 0,
            payload.count <= 8 * 1024 * 1024,
            (try? JSONSerialization.jsonObject(with: payload, options: .fragmentsAllowed)) != nil
        else { throw HostCLIError.rejected("Edith returned an invalid command result.") }
        return payload
    }
}

final class HostCLIConnection: @unchecked Sendable {
    let descriptor: Int32
    private let lock = NSLock()
    private var closed = false
    init(_ descriptor: Int32) { self.descriptor = descriptor }
    deinit { close() }
    func cancel() { lock.withLock { if !closed { _ = Darwin.shutdown(descriptor, SHUT_RDWR) } } }
    func close() { lock.withLock { if !closed { closed = true; _ = Darwin.close(descriptor) } } }
    func configure(timeout: Double) throws {
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        var value = timeval(tv_sec: Int(timeout), tv_usec: 0)
        var noSignal: Int32 = 1
        guard
            setsockopt(
                descriptor, SOL_SOCKET, SO_RCVTIMEO, &value, socklen_t(MemoryLayout<timeval>.size))
                == 0,
            setsockopt(
                descriptor, SOL_SOCKET, SO_SNDTIMEO, &value, socklen_t(MemoryLayout<timeval>.size))
                == 0,
            setsockopt(
                descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size)
            ) == 0
        else { throw HostCLIError.unavailable }
    }
    func read(limit: Int) throws -> Data {
        let header = try readBytes(4)
        let size = header.reduce(0) { ($0 << 8) | Int($1) }
        guard (1...limit).contains(size) else {
            throw HostCLIError.usage("The request exceeds its size limit.")
        }
        return try readBytes(size)
    }
    private func readBytes(_ count: Int) throws -> Data {
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { bytes in
            var offset = 0
            while offset < count {
                let received = Darwin.read(
                    descriptor, bytes.baseAddress!.advanced(by: offset), count - offset)
                if received < 0, errno == EINTR { continue }
                if received < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                    throw HostCLIError.timedOut
                }
                guard received > 0 else { throw HostCLIError.unavailable }
                offset += received
            }
        }
        return data
    }
    func write(_ data: Data, limit: Int) throws {
        guard data.count <= limit else {
            throw HostCLIError.rejected("The result exceeds its size limit.")
        }
        var size = UInt32(data.count).bigEndian
        var frame = withUnsafeBytes(of: &size) { Data($0) }
        frame.append(data)
        try frame.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let sent = Darwin.write(
                    descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if sent < 0, errno == EINTR { continue }
                guard sent > 0 else { throw HostCLIError.unavailable }
                offset += sent
            }
        }
    }
}
