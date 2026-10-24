import CryptoKit
import Darwin
import Foundation

public enum ExtensionPeerError: Error, LocalizedError, Sendable {
    case unavailable
    case invalidRequest
    case timedOut
    case rejected(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable: "Enable the required extension before using this action."
        case .invalidRequest: "The extension command is invalid or exceeds its size limit."
        case .timedOut: "The extension command did not finish within its time limit."
        case let .rejected(message): message
        }
    }
}

public struct ExtensionPeerEndpoint: Sendable {
    public let name: String
    public let directory: URL
    var registrationURL: URL { directory.appendingPathComponent(name + ".json") }
    public static let maximumPayloadBytes = 8 * 1_024 * 1_024
    public static let maximumConcurrentCommands = 32
    static let maximumConnections = 64
    static let maximumMessageBytes = 12 * 1_024 * 1_024

    public init(namespace: String, owner: String, directory: URL) throws {
        guard directory.isFileURL, directory.path.hasPrefix("/"), !directory.path.utf8.contains(0),
            !namespace.isEmpty, namespace.utf8.count <= 256, !namespace.utf8.contains(0),
            !owner.isEmpty, owner.count <= 96,
            owner.utf8.allSatisfy({
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                    || [45, 46, 95].contains($0)
            })
        else { throw ExtensionPeerError.invalidRequest }
        let hash = SHA256.hash(data: Data((namespace + "\0" + owner).utf8)).map {
            String(format: "%02x", $0)
        }.joined()
        self.directory = directory.standardizedFileURL
        name = "edith.extension.v1.\(getuid()).\(hash)"
    }

    public static func current(owner: String) -> Self? {
        guard let namespace = ExtensionEnvironment.values["EDITH_APPLICATION_IDENTIFIER"]
        else { return nil }
        guard let channel = ExtensionSharedState.current else { return nil }
        return try? Self(
            namespace: namespace, owner: owner,
            directory: channel.root.appendingPathComponent("Commands"))
    }

    public func invoke(
        _ command: String, payload: Data = Data(), timeout: TimeInterval = 30, token: UUID = UUID()
    )
        async throws -> Data
    {
        guard !command.isEmpty, command.utf8.count <= 256, !command.utf8.contains(0),
            payload.count <= Self.maximumPayloadBytes, timeout.isFinite, timeout > 0,
            timeout <= 1_800
        else { throw ExtensionPeerError.invalidRequest }
        let call = ExtensionPeerCall(
            endpoint: self, command: command, payload: payload, timeout: timeout, token: token)
        return try await withTaskCancellationHandler {
            try await call.run()
        } onCancel: {
            call.cancel()
        }
    }
}

struct ExtensionPeerRequest: Codable, Sendable {
    let token: UUID
    let command: String
    let payload: Data
    let timeout: TimeInterval
}

struct ExtensionPeerResponse: Codable, Sendable {
    let token: UUID
    let payload: Data?
    let message: String?
}

enum ExtensionPeerSocket {
    static let directory = URL(fileURLWithPath: "/tmp/edith-extensions-\(getuid())")

    static func path(_ name: String) -> String {
        let hash = SHA256.hash(data: Data(name.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(String(hash.prefix(48)) + ".sock").path
    }

    static func prepare() throws {
        if mkdir(directory.path, 0o700) != 0, errno != EEXIST {
            throw ExtensionPeerError.unavailable
        }
        var attributes = stat()
        guard lstat(directory.path, &attributes) == 0,
            attributes.st_mode & S_IFMT == S_IFDIR, attributes.st_uid == getuid(),
            attributes.st_mode & 0o777 == 0o700
        else { throw ExtensionPeerError.unavailable }
    }
}

enum ExtensionPeerFrame {
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let body = try encoder.encode(value)
        guard body.count <= ExtensionPeerEndpoint.maximumMessageBytes else {
            throw ExtensionPeerError.invalidRequest
        }
        var length = UInt32(body.count).bigEndian
        var frame = withUnsafeBytes(of: &length) { Data($0) }
        frame.append(body)
        return frame
    }
}

final class ExtensionPeerSocketConnection: @unchecked Sendable {
    let descriptor: Int32
    private let lock = NSLock()
    private var cancelled = false
    private var closed = false
    private var authenticatedPeer: ExtensionPeerProcess?

    init(descriptor: Int32) throws {
        self.descriptor = descriptor
        let flags = fcntl(descriptor, F_GETFL)
        var noSignal: Int32 = 1
        guard descriptor >= 0, flags >= 0,
            fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0,
            fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0,
            setsockopt(
                descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal,
                socklen_t(MemoryLayout<Int32>.size)) == 0
        else {
            close()
            throw ExtensionPeerError.unavailable
        }
    }

    convenience init() throws {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw ExtensionPeerError.unavailable }
        try self.init(descriptor: descriptor)
    }

    deinit { close() }

    func cancel() {
        lock.withLock {
            guard !closed, !cancelled else { return }
            cancelled = true
            _ = Darwin.shutdown(descriptor, SHUT_RDWR)
        }
    }

    func close() {
        lock.withLock {
            guard !closed else { return }
            closed = true
            _ = Darwin.close(descriptor)
        }
    }

    func check(deadline: DispatchTime) throws {
        let state = lock.withLock { (cancelled, closed) }
        if state.0 { throw CancellationError() }
        guard !state.1 else { throw ExtensionPeerError.unavailable }
        guard DispatchTime.now().uptimeNanoseconds < deadline.uptimeNanoseconds else {
            throw ExtensionPeerError.timedOut
        }
    }

    func wait(for events: Int16, deadline: DispatchTime) throws {
        while true {
            try check(deadline: deadline)
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline.uptimeNanoseconds else { throw ExtensionPeerError.timedOut }
            let remaining = deadline.uptimeNanoseconds - now
            let milliseconds = Int32(max(1, min(50, (remaining + 999_999) / 1_000_000)))
            var event = pollfd(fd: descriptor, events: events, revents: 0)
            let result = Darwin.poll(&event, 1, milliseconds)
            if result < 0, errno == EINTR { continue }
            guard result >= 0 else { throw ExtensionPeerError.unavailable }
            try check(deadline: deadline)
            if result > 0 {
                guard event.revents & Int16(POLLNVAL) == 0 else {
                    throw ExtensionPeerError.unavailable
                }
                return
            }
        }
    }

    func connect(path: String, deadline: DispatchTime) throws {
        try check(deadline: deadline)
        var address = sockaddr_un()
        guard !path.utf8.contains(0), path.utf8.count < MemoryLayout.size(ofValue: address.sun_path)
        else { throw ExtensionPeerError.invalidRequest }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) {
            $0.copyBytes(from: Array(path.utf8) + [0])
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        let error = errno
        try check(deadline: deadline)
        if result != 0 {
            guard error == EINPROGRESS || error == EINTR else {
                ExtensionPeerFailureDiagnostics.report(.connectionFailed, errorNumber: error)
                throw ExtensionPeerError.unavailable
            }
            try finishConnection(deadline: deadline)
        }
        try check(deadline: deadline)
    }

    func finishConnection(deadline: DispatchTime) throws {
        try wait(for: Int16(POLLOUT), deadline: deadline)
        var error: Int32 = 0
        var size = socklen_t(MemoryLayout<Int32>.size)
        let result = getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &error, &size)
        let systemError = errno
        try check(deadline: deadline)
        guard result == 0, size == MemoryLayout<Int32>.size, error == 0
        else {
            ExtensionPeerFailureDiagnostics.report(
                .connectionFailed,
                errorNumber: error == 0 ? systemError : error)
            throw ExtensionPeerError.unavailable
        }
    }

    func capturePeer(expected: ExtensionProcessIdentity, deadline: DispatchTime) throws {
        try check(deadline: deadline)
        var uid: uid_t = 0
        var gid: gid_t = 0
        var pid: Int32 = 0
        var size = socklen_t(MemoryLayout<Int32>.size)
        guard getpeereid(descriptor, &uid, &gid) == 0, uid == getuid(),
            getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) == 0,
            size == MemoryLayout<Int32>.size,
            let actual = ExtensionPeerProcess.read(pid), actual.birth == expected,
            actual.isCurrent,
            lock.withLock({
                guard !closed, !cancelled, authenticatedPeer == nil else { return false }
                authenticatedPeer = actual
                return true
            })
        else {
            try check(deadline: deadline)
            ExtensionPeerFailureDiagnostics.report(.clientAuthentication)
            throw ExtensionPeerError.unavailable
        }
        try check(deadline: deadline)
    }

    func revalidatePeer(expected: ExtensionProcessIdentity, deadline: DispatchTime) throws {
        try check(deadline: deadline)
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard let peer = lock.withLock({ authenticatedPeer }), peer.birth == expected,
            getpeereid(descriptor, &uid, &gid) == 0, uid == getuid(), peer.isCurrent
        else {
            try check(deadline: deadline)
            ExtensionPeerFailureDiagnostics.report(.clientAuthentication)
            throw ExtensionPeerError.unavailable
        }
        try check(deadline: deadline)
    }

    func writeFrame(_ frame: Data, deadline: DispatchTime) throws {
        guard frame.count > 4, frame.count <= ExtensionPeerEndpoint.maximumMessageBytes + 4
        else { throw ExtensionPeerError.invalidRequest }
        try frame.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                try check(deadline: deadline)
                let sent = Darwin.write(
                    descriptor, bytes.baseAddress!.advanced(by: offset),
                    bytes.count - offset)
                let error = errno
                try check(deadline: deadline)
                if sent < 0, error == EINTR { continue }
                if sent < 0, error == EAGAIN || error == EWOULDBLOCK {
                    try wait(for: Int16(POLLOUT), deadline: deadline)
                    continue
                }
                guard sent > 0 else {
                    ExtensionPeerFailureDiagnostics.report(.sendFailed, errorNumber: error)
                    throw ExtensionPeerError.unavailable
                }
                offset += sent
            }
        }
    }

    func readFrame(deadline: DispatchTime) throws -> Data {
        let header = try readBytes(4, deadline: deadline)
        let count = header.reduce(0) { ($0 << 8) | Int($1) }
        guard count > 0, count <= ExtensionPeerEndpoint.maximumMessageBytes else {
            throw ExtensionPeerError.invalidRequest
        }
        return try readBytes(count, deadline: deadline)
    }

    private func readBytes(_ count: Int, deadline: DispatchTime) throws -> Data {
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { bytes in
            var offset = 0
            while offset < count {
                try check(deadline: deadline)
                let received = Darwin.read(
                    descriptor, bytes.baseAddress!.advanced(by: offset),
                    count - offset)
                let error = errno
                try check(deadline: deadline)
                if received < 0, error == EINTR { continue }
                if received < 0, error == EAGAIN || error == EWOULDBLOCK {
                    try wait(for: Int16(POLLIN), deadline: deadline)
                    continue
                }
                guard received > 0 else {
                    ExtensionPeerFailureDiagnostics.report(
                        .responseReadUnavailable,
                        errorNumber: received < 0 ? error : nil)
                    throw ExtensionPeerError.unavailable
                }
                offset += received
            }
        }
        return data
    }
}

private final class ExtensionPeerCall: @unchecked Sendable {
    private let endpoint: ExtensionPeerEndpoint
    private let request: ExtensionPeerRequest
    private let queue = DispatchQueue(label: "edith.extension.command", qos: .utility)
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, any Error>?
    private var result: Result<Data, any Error>?
    private var connection: ExtensionPeerSocketConnection?
    private let work = ExtensionPeerWork()

    init(
        endpoint: ExtensionPeerEndpoint, command: String, payload: Data, timeout: TimeInterval,
        token: UUID
    ) {
        self.endpoint = endpoint
        request = ExtensionPeerRequest(
            token: token, command: command, payload: payload,
            timeout: timeout)
    }

    func run() async throws -> Data {
        let outcome: Result<Data, any Error>
        do {
            let payload = try await withCheckedThrowingContinuation { continuation in
                let previous = lock.withLock { () -> Result<Data, any Error>? in
                    if let result { return result }
                    self.continuation = continuation
                    work.schedule(on: queue) { [self] in send() }
                    return nil
                }
                if let previous { continuation.resume(with: previous) }
            }
            outcome = .success(payload)
        } catch { outcome = .failure(error) }
        await work.closeAndWait()
        lock.withLock { connection = nil }
        return try outcome.get()
    }

    func cancel() { finish(.failure(CancellationError())) }

    private func send() {
        guard lock.withLock({ result == nil }) else { return }
        do {
            guard
                let registration = ExtensionPeerRegistration.read(
                    at: endpoint.registrationURL,
                    logicalName: endpoint.name, reportFailures: true)
            else { throw ExtensionPeerError.unavailable }
            let frame = try ExtensionPeerFrame.encode(request)
            let connection = try ExtensionPeerSocketConnection()
            defer { connection.close() }
            guard
                lock.withLock({
                    guard result == nil else { return false }
                    self.connection = connection
                    return true
                })
            else { return }
            let deadline = DispatchTime.now() + request.timeout
            let path = ExtensionPeerSocket.path(registration.physicalName)
            var parent = stat()
            var socket = stat()
            guard lstat(ExtensionPeerSocket.directory.path, &parent) == 0,
                parent.st_mode & S_IFMT == S_IFDIR, parent.st_uid == getuid(),
                parent.st_mode & 0o777 == 0o700, lstat(path, &socket) == 0,
                socket.st_mode & S_IFMT == S_IFSOCK, socket.st_uid == getuid(),
                socket.st_mode & 0o777 == 0o600
            else { throw ExtensionPeerError.unavailable }
            try connection.connect(path: path, deadline: deadline)
            try connection.capturePeer(
                expected: registration.process, deadline: deadline)
            try connection.writeFrame(frame, deadline: deadline)
            try connection.revalidatePeer(
                expected: registration.process, deadline: deadline)
            let data = try connection.readFrame(deadline: deadline)
            try connection.revalidatePeer(
                expected: registration.process, deadline: deadline)
            try connection.check(deadline: deadline)
            try receive(data, connection: connection, deadline: deadline)
        } catch { finish(.failure(error)) }
    }

    private func receive(
        _ data: Data, connection: ExtensionPeerSocketConnection, deadline: DispatchTime
    ) throws {
        let decoded = try? JSONDecoder().decode(ExtensionPeerResponse.self, from: data)
        try connection.check(deadline: deadline)
        guard let response = decoded, response.token == request.token
        else { finish(.failure(ExtensionPeerError.invalidRequest)); return }
        if let payload = response.payload,
            payload.count <= ExtensionPeerEndpoint.maximumPayloadBytes
        {
            finish(.success(payload))
        } else {
            finish(
                .failure(
                    ExtensionPeerError.rejected(
                        response.message ?? "The extension command failed.")))
        }
    }

    private func finish(_ result: Result<Data, any Error>) {
        let resources = lock.withLock {
            () -> (CheckedContinuation<Data, any Error>?, ExtensionPeerSocketConnection?)? in
            guard self.result == nil else { return nil }
            self.result = result
            let resources = (continuation, connection)
            continuation = nil
            return resources
        }
        guard let resources else { return }
        resources.1?.cancel()
        resources.0?.resume(with: result)
    }
}

@_silgen_name("csops")
private func extensionPeerCodeSigningOperation(
    _ pid: Int32, _ operation: UInt32, _ buffer: UnsafeMutableRawPointer, _ count: Int
) -> Int32

public struct ExtensionPeerProcess: Codable, Equatable, Sendable {
    public let birth: ExtensionProcessIdentity
    public let executable: String
    public let codeHash: Data

    public var isCurrent: Bool { Self.read(birth.pid) == self }

    public static func read(_ pid: Int32) -> Self? {
        var info = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.size
        guard pid > 1, proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(size)) == size,
            info.pbi_uid == getuid(), info.pbi_ruid == getuid()
        else { return nil }
        let birth = ExtensionProcessIdentity(
            pid: pid, generation: "\(info.pbi_start_tvsec).\(info.pbi_start_tvusec)")
        var path = [CChar](repeating: 0, count: 4096)
        var hash = [UInt8](repeating: 0, count: 20)
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0,
            extensionPeerCodeSigningOperation(pid, 5, &hash, hash.count) == 0,
            hash.contains(where: { $0 != 0 }), ExtensionProcessIdentity.read(pid) == birth
        else { return nil }
        return Self(
            birth: birth,
            executable: String(
                decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self),
            codeHash: Data(hash))
    }

    static func peer(_ descriptor: Int32) throws -> Self {
        var uid: uid_t = 0
        var gid: gid_t = 0
        var pid: Int32 = 0
        var size = socklen_t(MemoryLayout<Int32>.size)
        guard getpeereid(descriptor, &uid, &gid) == 0 else {
            ExtensionPeerFailureDiagnostics.report(.serverPeerCredentials, errorNumber: errno)
            throw ExtensionPeerError.unavailable
        }
        guard uid == getuid() else {
            ExtensionPeerFailureDiagnostics.report(.serverPeerUID)
            throw ExtensionPeerError.unavailable
        }
        guard getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) == 0 else {
            ExtensionPeerFailureDiagnostics.report(.serverPeerPID, errorNumber: errno)
            throw ExtensionPeerError.unavailable
        }
        guard size == MemoryLayout<Int32>.size else {
            ExtensionPeerFailureDiagnostics.report(.serverPeerPIDSize)
            throw ExtensionPeerError.unavailable
        }
        guard let peer = read(pid) else {
            ExtensionPeerFailureDiagnostics.report(.serverPeerIdentity)
            throw ExtensionPeerError.unavailable
        }
        return peer
    }
}

final class ExtensionPeerWork: @unchecked Sendable {
    private let group = DispatchGroup()

    func begin() { group.enter() }
    func end() { group.leave() }

    func schedule(on queue: DispatchQueue, action: @escaping @Sendable () -> Void) {
        queue.async(group: group, execute: action)
    }

    @discardableResult
    func task(_ action: @escaping @MainActor @Sendable () async -> Void) -> Task<Void, Never> {
        begin()
        let actual = Task { @MainActor in await action() }
        Task { [self] in
            await actual.value; end()
        }
        return actual
    }

    func closeAndWait() async {
        await withCheckedContinuation { continuation in
            group.notify(queue: .global(qos: .utility)) { continuation.resume() }
        }
    }
}

private final class ExtensionPeerConnection: @unchecked Sendable {
    let descriptor: Int32
    let source: ExtensionPeerProcess
    private let lock = NSLock()
    private var cancelled = false
    private var descriptorClosed = false
    private let work = ExtensionPeerWork()
    private let queue = DispatchQueue(label: "edith.extension.peer.read", qos: .utility)
    private let writeQueue = DispatchQueue(label: "edith.extension.peer.write", qos: .utility)

    private init(_ descriptor: Int32, source: ExtensionPeerProcess) {
        self.descriptor = descriptor
        self.source = source
    }

    static func accept(_ descriptor: Int32) throws -> ExtensionPeerConnection {
        let source = try ExtensionPeerProcess.peer(descriptor)
        let flags = fcntl(descriptor, F_GETFL)
        var noSignal: Int32 = 1
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags & ~O_NONBLOCK) == 0,
            fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0,
            setsockopt(
                descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size)
            ) == 0
        else {
            ExtensionPeerFailureDiagnostics.report(.serverSocketConfiguration, errorNumber: errno)
            throw ExtensionPeerError.unavailable
        }
        return ExtensionPeerConnection(descriptor, source: source)
    }

    deinit { closeDescriptor() }

    private func closeDescriptor() {
        lock.withLock {
            guard !descriptorClosed else { return }
            descriptorClosed = true
            _ = Darwin.close(descriptor)
        }
    }

    func retire() async {
        cancel()
        await work.closeAndWait()
        closeDescriptor()
    }

    func scheduleCallback(_ action: @escaping @MainActor @Sendable () -> Void) {
        work.task { action() }
    }

    func cancel() {
        lock.withLock {
            guard !cancelled else { return }
            cancelled = true
            _ = Darwin.shutdown(descriptor, SHUT_RDWR)
        }
    }

    func authenticate() throws {
        guard !lock.withLock({ cancelled }), source.isCurrent,
            try ExtensionPeerProcess.peer(descriptor) == source
        else {
            if !lock.withLock({ cancelled }) {
                ExtensionPeerFailureDiagnostics.report(.serverAuthentication)
            }
            throw ExtensionPeerError.unavailable
        }
    }

    func receive(_ completion: @escaping @Sendable (Result<Data, Error>) -> Void) {
        work.schedule(on: queue) { [self] in
            do {
                try authenticate()
                let header = try readBytes(4)
                let count = header.reduce(0) { ($0 << 8) | Int($1) }
                guard count > 0, count <= ExtensionPeerEndpoint.maximumMessageBytes else {
                    throw ExtensionPeerError.invalidRequest
                }
                let body = try readBytes(count)
                try authenticate()
                completion(.success(body))
            } catch { completion(.failure(error)) }
        }
    }

    func observeDisconnect(_ completion: @escaping @Sendable () -> Void) {
        work.schedule(on: queue) { [self] in
            var byte: UInt8 = 0
            while Darwin.read(descriptor, &byte, 1) < 0, errno == EINTR {}
            completion()
        }
    }

    func send(_ frame: Data, completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
        work.schedule(on: writeQueue) { [self] in
            do {
                try authenticate()
                try frame.withUnsafeBytes { bytes in
                    var offset = 0
                    while offset < bytes.count {
                        let count = Darwin.write(
                            descriptor, bytes.baseAddress!.advanced(by: offset),
                            bytes.count - offset)
                        if count < 0, errno == EINTR { continue }
                        guard count > 0 else { throw ExtensionPeerError.unavailable }
                        offset += count
                    }
                }
                try authenticate()
                completion(.success(()))
            } catch { completion(.failure(error)) }
        }
    }

    private func readBytes(_ count: Int) throws -> Data {
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { bytes in
            var offset = 0
            while offset < count {
                let received = Darwin.read(
                    descriptor, bytes.baseAddress!.advanced(by: offset), count - offset)
                if received < 0, errno == EINTR { continue }
                guard received > 0 else { throw ExtensionPeerError.unavailable }
                offset += received
            }
        }
        return data
    }
}

@MainActor
public final class ExtensionPeerServer {
    public typealias Execute = @MainActor @Sendable (UUID, String, Data) async throws -> Data
    #if EDITH_FUNCTIONAL_FIXTURE
    public struct FixtureInvocation: Codable, Sendable {
        public let endpoint: String
        public let source: ExtensionPeerProcess
        public let receiver: ExtensionPeerProcess
        public let token: UUID
        public let command: String
        public let payload: Data
    }
    public static var fixtureBeforeExecute: ((FixtureInvocation) async throws -> Void)?
    public static var fixtureAfterExecute:
        ((FixtureInvocation, Data?, String?) async throws -> Void)?
    #endif
    private struct Job {
        let connection: ExtensionPeerConnection
        var task: Task<Void, Never>?
        var deadline: Task<Void, Never>
    }
    private let endpoint: ExtensionPeerEndpoint
    private let execute: Execute
    private let controlsDuringDrain: Set<String>
    private enum Admission: Equatable {
        case open
        case draining
        case stopped
        case starting(UUID)
    }
    private var admission = Admission.open
    private var retirement: Task<Void, Never>?
    private var ownedCallbacks = ExtensionPeerWork()
    private var listenerWork = ExtensionPeerWork()
    private var ownedConnections: [UUID: ExtensionPeerConnection] = [:]
    private let queue = DispatchQueue(label: "edith.extension.commands", qos: .utility)
    private var listener: DispatchSourceRead?
    private var listenerDescriptor: Int32?
    private var listenerGeneration: UUID?
    private var jobs: [UUID: Job] = [:]
    private var executing: [UUID: Task<Void, Never>] = [:]
    private var registration: ExtensionPeerRegistrationLease?

    public init(
        endpoint: ExtensionPeerEndpoint, controlsDuringDrain: Set<String> = [],
        execute: @escaping Execute
    ) {
        self.endpoint = endpoint
        self.execute = execute
        self.controlsDuringDrain = controlsDuringDrain
    }

    public func start() throws {
        guard listener == nil, admission != .draining, controlsDuringDrain.count <= 16,
            controlsDuringDrain.allSatisfy({
                !$0.isEmpty && $0.utf8.count <= 256 && !$0.utf8.contains(0)
            })
        else { throw ExtensionPeerError.invalidRequest }
        let registration = try ExtensionPeerRegistrationLease(endpoint: endpoint)
        try ExtensionPeerSocket.prepare()
        let path = ExtensionPeerSocket.path(registration.registration.physicalName)
        var address = sockaddr_un()
        guard path.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw ExtensionPeerError.unavailable
        }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { bytes in
            bytes.copyBytes(from: Array(path.utf8) + [0])
        }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw ExtensionPeerError.unavailable }
        var handedOff = false
        defer { if !handedOff { Darwin.close(descriptor); unlink(path) } }
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0,
            fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0,
            withUnsafePointer(
                to: &address,
                { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                    }
                }) == 0, chmod(path, 0o600) == 0,
            Darwin.listen(descriptor, Int32(ExtensionPeerEndpoint.maximumConnections)) == 0
        else { throw ExtensionPeerError.unavailable }
        let generation = UUID()
        let previousRetirement = retirement
        ownedCallbacks = ExtensionPeerWork()
        let listenerWork = ExtensionPeerWork()
        self.listenerWork = listenerWork
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        listenerWork.begin()
        source.setEventHandler { [weak self, source, listenerWork] in
            source.suspend()
            listenerWork.task { [weak self] in
                defer { source.resume() }
                self?.acceptAvailable(descriptor, generation: generation)
            }
        }
        source.setCancelHandler { [listenerWork, queue] in
            Darwin.close(descriptor)
            queue.async { listenerWork.end() }
        }
        listener = source
        listenerDescriptor = descriptor
        listenerGeneration = generation
        self.registration = registration
        handedOff = true
        if let previousRetirement {
            admission = .starting(generation)
            Task { [weak self, source] in
                await previousRetirement.value
                if self?.admission == .starting(generation) { self?.admission = .open }
                source.activate()
            }
        } else {
            admission = .open
            source.activate()
        }
        do { try registration.publish() } catch { shutdown(); throw error }
    }

    public func shutdown() {
        admission = .stopped
        listener?.cancel()
        listener = nil
        listenerDescriptor = nil
        listenerGeneration = nil
        if let registration {
            unlink(ExtensionPeerSocket.path(registration.registration.physicalName))
            registration.release()
        }
        registration = nil
        for token in Array(jobs.keys) { close(token) }
        let previousRetirement = retirement
        let tasks = executing
        let connections = Array(ownedConnections.values)
        let listenerWork = self.listenerWork
        let ownedCallbacks = self.ownedCallbacks
        for task in tasks.values { task.cancel() }
        retirement = Task {
            await previousRetirement?.value
            for task in tasks.values { await task.value }
            for connection in connections { await connection.retire() }
            await listenerWork.closeAndWait()
            await ownedCallbacks.closeAndWait()
        }
    }

    public func closeMutationAdmission() { admission = .draining }

    public func cancelAndJoinRequests() async {
        admission = .draining
        let snapshot = executing
        for task in snapshot.values { task.cancel() }
        for (token, task) in snapshot {
            await task.value
            executing[token] = nil
        }
    }

    public func shutdownAndWait() async {
        shutdown()
        await retirement?.value
    }

    private func acceptAvailable(_ descriptor: Int32, generation: UUID) {
        guard listenerDescriptor == descriptor, listenerGeneration == generation else { return }
        for _ in 0..<32 {
            let client = Darwin.accept(descriptor, nil, nil)
            if client < 0 { return }
            guard ownedConnections.count < ExtensionPeerEndpoint.maximumConnections,
                executing.count < ExtensionPeerEndpoint.maximumConcurrentCommands
            else {
                Darwin.close(client); continue
            }
            do {
                let connection = try ExtensionPeerConnection.accept(client)
                accept(connection)
            } catch { Darwin.close(client) }
        }
    }

    private func accept(_ connection: ExtensionPeerConnection) {
        let token = UUID()
        ownedConnections[token] = connection
        let deadline = ownedCallbacks.task { [weak self] in
            do { try await Task.sleep(for: .seconds(5)); self?.close(token) } catch {}
        }
        jobs[token] = Job(connection: connection, task: nil, deadline: deadline)
        connection.receive { [weak self, weak connection] result in
            connection?.scheduleCallback { [weak self] in self?.receive(result, token: token) }
        }
    }

    private func receive(_ result: Result<Data, Error>, token: UUID) {
        guard var job = jobs[token] else { return }
        guard case let .success(data) = result else { close(token); return }
        guard let request = try? JSONDecoder().decode(ExtensionPeerRequest.self, from: data),
            !request.command.isEmpty, request.command.utf8.count <= 256,
            !request.command.utf8.contains(0),
            request.payload.count <= ExtensionPeerEndpoint.maximumPayloadBytes,
            request.timeout.isFinite, request.timeout > 0, request.timeout <= 1_800
        else {
            ExtensionPeerFailureDiagnostics.report(.serverReceive)
            close(token)
            return
        }
        guard admission == .open || controlsDuringDrain.contains(request.command) else {
            ExtensionPeerFailureDiagnostics.report(.serverAdmission)
            close(token); return
        }
        job.deadline.cancel()
        job.deadline = ownedCallbacks.task { [weak self] in
            do { try await Task.sleep(for: .seconds(request.timeout)); self?.close(token) } catch {}
        }
        let connection = job.connection
        job.task = Task { [self, execute] in
            do {
                try connection.authenticate()
                #if EDITH_FUNCTIONAL_FIXTURE
                guard let before = Self.fixtureBeforeExecute,
                    let after = Self.fixtureAfterExecute,
                    let receiver = ExtensionPeerProcess.read(getpid()), receiver.isCurrent
                else { throw ExtensionPeerError.unavailable }
                let invocation = FixtureInvocation(
                    endpoint: self.endpoint.name, source: connection.source, receiver: receiver,
                    token: request.token, command: request.command, payload: request.payload)
                try await before(invocation)
                try Task.checkCancellation()
                try connection.authenticate()
                guard receiver.isCurrent else { throw ExtensionPeerError.unavailable }
                #endif
                let outcome: Result<Data, Error>
                do {
                    let payload = try await execute(request.token, request.command, request.payload)
                    try Task.checkCancellation()
                    guard payload.count <= ExtensionPeerEndpoint.maximumPayloadBytes else {
                        throw ExtensionPeerError.invalidRequest
                    }
                    outcome = .success(payload)
                } catch { outcome = .failure(error) }
                try connection.authenticate()
                #if EDITH_FUNCTIONAL_FIXTURE
                guard receiver.isCurrent else { throw ExtensionPeerError.unavailable }
                switch outcome {
                case let .success(payload): try await after(invocation, payload, nil)
                case let .failure(error):
                    try await after(
                        invocation, nil, String(error.localizedDescription.prefix(2_048)))
                }
                try connection.authenticate()
                guard receiver.isCurrent else { throw ExtensionPeerError.unavailable }
                #endif
                self.complete(
                    token,
                    response: ExtensionPeerResponse(
                        token: request.token, payload: try outcome.get(), message: nil))
            } catch {
                self.complete(
                    token,
                    response: ExtensionPeerResponse(
                        token: request.token, payload: nil,
                        message: String(error.localizedDescription.prefix(2_048))))
            }
        }
        jobs[token] = job
        if let task = job.task {
            executing[token] = task
            ownedCallbacks.task { [self] in
                await task.value
                executing[token] = nil
            }
        }
        connection.observeDisconnect { [weak self, weak connection] in
            connection?.scheduleCallback { [weak self] in self?.close(token) }
        }
    }

    private func complete(_ token: UUID, response: ExtensionPeerResponse) {
        guard let job = jobs[token], let frame = try? ExtensionPeerFrame.encode(response) else {
            close(token)
            return
        }
        job.connection.send(frame) { [weak self, weak connection = job.connection] _ in
            connection?.scheduleCallback { [weak self] in self?.close(token) }
        }
    }

    private func close(_ token: UUID) {
        guard let job = jobs.removeValue(forKey: token) else { return }
        job.task?.cancel()
        job.deadline.cancel()
        job.connection.cancel()
        ownedCallbacks.task { [self] in
            await job.connection.retire()
            ownedConnections[token] = nil
        }
    }
}
