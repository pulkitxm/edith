import CryptoKit
import Darwin
import Foundation
import Network

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
        guard let namespace = ProcessInfo.processInfo.environment["EDITH_APPLICATION_IDENTIFIER"]
        else { return nil }
        guard let channel = ExtensionSharedState.current else { return nil }
        return try? Self(
            namespace: namespace, owner: owner,
            directory: channel.root.appendingPathComponent("Commands"))
    }

    public func invoke(_ command: String, payload: Data = Data(), timeout: TimeInterval = 30)
        async throws -> Data
    {
        guard !command.isEmpty, command.utf8.count <= 256, !command.utf8.contains(0),
            payload.count <= Self.maximumPayloadBytes, timeout.isFinite, timeout > 0,
            timeout <= 1_800
        else { throw ExtensionPeerError.invalidRequest }
        let call = ExtensionPeerCall(
            endpoint: self, command: command, payload: payload, timeout: timeout)
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

    static func receive(
        from connection: NWConnection, completion: @escaping (Result<Data, any Error>) -> Void
    ) {
        read(from: connection, remaining: 4, buffer: Data()) { result in
            switch result {
            case let .failure(error): completion(.failure(error))
            case let .success(header):
                let count = header.reduce(0) { ($0 << 8) | Int($1) }
                guard count > 0, count <= ExtensionPeerEndpoint.maximumMessageBytes else {
                    completion(.failure(ExtensionPeerError.invalidRequest))
                    return
                }
                read(from: connection, remaining: count, buffer: Data(), completion: completion)
            }
        }
    }

    private static func read(
        from connection: NWConnection, remaining: Int, buffer: Data,
        completion: @escaping (Result<Data, any Error>) -> Void
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: min(remaining, 65_536)) {
            bytes, _, complete, error in
            guard error == nil, let bytes, !bytes.isEmpty, bytes.count <= remaining else {
                completion(.failure(ExtensionPeerError.unavailable))
                return
            }
            var buffer = buffer
            buffer.append(bytes)
            if bytes.count == remaining {
                completion(.success(buffer))
            } else if complete {
                completion(.failure(ExtensionPeerError.unavailable))
            } else {
                read(
                    from: connection, remaining: remaining - bytes.count, buffer: buffer,
                    completion: completion)
            }
        }
    }
}

private final class ExtensionPeerCall: @unchecked Sendable {
    private let endpoint: ExtensionPeerEndpoint
    private let request: ExtensionPeerRequest
    private let queue = DispatchQueue(label: "edith.extension.command", qos: .utility)
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, any Error>?
    private var result: Result<Data, any Error>?
    private var connection: NWConnection?
    private var timer: DispatchSourceTimer?

    init(endpoint: ExtensionPeerEndpoint, command: String, payload: Data, timeout: TimeInterval) {
        self.endpoint = endpoint
        request = ExtensionPeerRequest(
            token: UUID(), command: command, payload: payload, timeout: timeout)
    }

    func run() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let previous = lock.withLock { () -> Result<Data, any Error>? in
                if let result { return result }
                self.continuation = continuation
                return nil
            }
            if let previous { continuation.resume(with: previous); return }
            queue.async { [self] in send() }
        }
    }

    func cancel() { finish(.failure(CancellationError())) }

    private func send() {
        do {
            guard
                let registration = ExtensionPeerRegistration.read(
                    at: endpoint.registrationURL, logicalName: endpoint.name)
            else { throw ExtensionPeerError.unavailable }
            let frame = try ExtensionPeerFrame.encode(request)
            let connection = NWConnection(
                to: .unix(path: ExtensionPeerSocket.path(registration.physicalName)), using: .tcp)
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + request.timeout)
            timer.setEventHandler { [weak self] in
                self?.finish(.failure(ExtensionPeerError.timedOut))
            }
            connection.stateUpdateHandler = { [weak self] state in
                if case .failed = state { self?.finish(.failure(ExtensionPeerError.unavailable)) }
            }
            timer.activate()
            let started = lock.withLock { () -> Bool in
                guard result == nil else { return false }
                self.connection = connection
                self.timer = timer
                return true
            }
            guard started else { timer.cancel(); connection.cancel(); return }
            connection.start(queue: queue)
            connection.send(
                content: frame,
                completion: .contentProcessed { [weak self] error in
                    if error != nil { self?.finish(.failure(ExtensionPeerError.unavailable)) }
                })
            ExtensionPeerFrame.receive(from: connection) { [weak self] result in
                guard let self else { return }
                switch result {
                case let .failure(error): self.finish(.failure(error))
                case let .success(data): self.receive(data)
                }
            }
        } catch { finish(.failure(error)) }
    }

    private func receive(_ data: Data) {
        guard let response = try? JSONDecoder().decode(ExtensionPeerResponse.self, from: data),
            response.token == request.token
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
            () -> (CheckedContinuation<Data, any Error>?, NWConnection?, DispatchSourceTimer?)? in
            guard self.result == nil else { return nil }
            self.result = result
            let resources = (continuation, connection, timer)
            continuation = nil
            connection = nil
            timer = nil
            return resources
        }
        guard let resources else { return }
        resources.1?.stateUpdateHandler = nil
        resources.1?.cancel()
        resources.2?.cancel()
        resources.0?.resume(with: result)
    }
}

private final class ExtensionPeerListenerReady: @unchecked Sendable {
    let signal = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var ready = false

    func update(_ state: NWListener.State) {
        switch state {
        case .ready:
            lock.withLock { ready = true }
            signal.signal()
        case .failed, .cancelled: signal.signal()
        default: break
        }
    }

    var succeeded: Bool { lock.withLock { ready } }
}

@MainActor
public final class ExtensionPeerServer {
    public typealias Execute = @MainActor @Sendable (UUID, String, Data) async throws -> Data
    private struct Job {
        let connection: NWConnection
        var task: Task<Void, Never>?
        var deadline: Task<Void, Never>
    }
    private let endpoint: ExtensionPeerEndpoint
    private let execute: Execute
    private let queue = DispatchQueue(label: "edith.extension.commands", qos: .utility)
    private var listener: NWListener?
    private var jobs: [UUID: Job] = [:]
    private var registration: ExtensionPeerRegistrationLease?

    public init(endpoint: ExtensionPeerEndpoint, execute: @escaping Execute) {
        self.endpoint = endpoint
        self.execute = execute
    }

    public func start() throws {
        guard listener == nil else { throw ExtensionPeerError.invalidRequest }
        let registration = try ExtensionPeerRegistrationLease(endpoint: endpoint)
        try ExtensionPeerSocket.prepare()
        let path = ExtensionPeerSocket.path(registration.registration.physicalName)
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .unix(path: path)
        let listener = try NWListener(using: parameters)
        let readiness = ExtensionPeerListenerReady()
        listener.stateUpdateHandler = { readiness.update($0) }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                guard let self else { connection.cancel(); return }
                self.accept(connection)
            }
        }
        self.listener = listener
        self.registration = registration
        listener.start(queue: queue)
        guard readiness.signal.wait(timeout: .now() + 3) == .success, readiness.succeeded else {
            shutdown()
            throw ExtensionPeerError.unavailable
        }
        listener.stateUpdateHandler = { [weak self] state in
            if case .failed = state { Task { @MainActor in self?.shutdown() } }
        }
        guard chmod(path, 0o600) == 0 else { shutdown(); throw ExtensionPeerError.unavailable }
        do { try registration.publish() } catch { shutdown(); throw error }
    }

    public func shutdown() {
        listener?.cancel()
        listener = nil
        if let registration {
            unlink(ExtensionPeerSocket.path(registration.registration.physicalName))
            registration.release()
        }
        registration = nil
        let pending = jobs.values
        jobs.removeAll()
        for job in pending {
            job.task?.cancel()
            job.deadline.cancel()
            job.connection.cancel()
        }
    }

    private func accept(_ connection: NWConnection) {
        guard listener != nil, jobs.count < 8 else { connection.cancel(); return }
        let token = UUID()
        let deadline = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(5))
                self?.close(token)
            } catch {}
        }
        jobs[token] = Job(connection: connection, task: nil, deadline: deadline)
        connection.start(queue: queue)
        ExtensionPeerFrame.receive(from: connection) { [weak self] result in
            Task { @MainActor in self?.receive(result, token: token) }
        }
    }

    private func receive(_ result: Result<Data, any Error>, token: UUID) {
        guard var job = jobs[token] else { return }
        guard case let .success(data) = result,
            let request = try? JSONDecoder().decode(ExtensionPeerRequest.self, from: data),
            !request.command.isEmpty, request.command.utf8.count <= 256,
            !request.command.utf8.contains(0),
            request.payload.count <= ExtensionPeerEndpoint.maximumPayloadBytes,
            request.timeout.isFinite, request.timeout > 0, request.timeout <= 1_800
        else { close(token); return }
        job.deadline.cancel()
        job.deadline = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(request.timeout))
                self?.close(token)
            } catch {}
        }
        job.task = Task { [weak self, execute] in
            do {
                let payload = try await execute(request.token, request.command, request.payload)
                try Task.checkCancellation()
                guard payload.count <= ExtensionPeerEndpoint.maximumPayloadBytes else {
                    throw ExtensionPeerError.invalidRequest
                }
                self?.complete(
                    token,
                    response: ExtensionPeerResponse(
                        token: request.token, payload: payload, message: nil))
            } catch {
                self?.complete(
                    token,
                    response: ExtensionPeerResponse(
                        token: request.token, payload: nil,
                        message: String(error.localizedDescription.prefix(2_048))))
            }
        }
        jobs[token] = job
        job.connection.receive(minimumIncompleteLength: 1, maximumLength: 1) {
            [weak self] _, _, _, _ in
            Task { @MainActor in self?.close(token) }
        }
    }

    private func complete(_ token: UUID, response: ExtensionPeerResponse) {
        guard let job = jobs[token], let frame = try? ExtensionPeerFrame.encode(response) else {
            close(token)
            return
        }
        job.connection.send(
            content: frame, contentContext: .finalMessage, isComplete: true,
            completion: .contentProcessed { [weak self] error in
                if error != nil { Task { @MainActor in self?.close(token) } }
            })
    }

    private func close(_ token: UUID) {
        guard let job = jobs.removeValue(forKey: token) else { return }
        job.task?.cancel()
        job.deadline.cancel()
        job.connection.cancel()
    }
}
