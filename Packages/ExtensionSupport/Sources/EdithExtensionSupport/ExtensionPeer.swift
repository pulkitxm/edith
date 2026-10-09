import CoreFoundation
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
    let reply: String
    let command: String
    let payload: Data
    let timeout: TimeInterval
}

struct ExtensionPeerResponse: Codable, Sendable {
    let token: UUID
    let payload: Data?
    let message: String?
}

private final class ExtensionPeerCall: @unchecked Sendable {
    private let endpoint: ExtensionPeerEndpoint
    private let request: ExtensionPeerRequest
    private let physicalName: String?
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, any Error>?
    private var result: Result<Data, any Error>?
    private var receiver: CFMessagePort?
    private var remote: CFMessagePort?
    private var timer: DispatchSourceTimer?

    init(endpoint: ExtensionPeerEndpoint, command: String, payload: Data, timeout: TimeInterval) {
        self.endpoint = endpoint
        physicalName =
            ExtensionPeerRegistration.read(
                at: endpoint.registrationURL, logicalName: endpoint.name)?.physicalName
        let token = UUID()
        request = ExtensionPeerRequest(
            token: token, reply: "edith.extension.reply.\(getuid()).\(token.uuidString)",
            command: command, payload: payload, timeout: timeout)
    }

    func run() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let previous = lock.withLock { () -> Result<Data, any Error>? in
                if let result { return result }
                self.continuation = continuation
                return nil
            }
            if let previous { continuation.resume(with: previous); return }
            DispatchQueue.global(qos: .utility).async { [self] in send() }
        }
    }

    func cancel() { stop(CancellationError()) }

    private func stop(_ error: any Error) {
        guard finish(.failure(error)) else { return }
        DispatchQueue.global(qos: .utility).async { [self] in
            guard let physicalName,
                let remote = CFMessagePortCreateRemote(nil, physicalName as CFString)
            else {
                return
            }
            let data = Data(request.token.uuidString.utf8)
            _ = CFMessagePortSendRequest(remote, 2, data as CFData, 0.25, 0, nil, nil)
        }
    }

    private func send() {
        do {
            let data = try JSONEncoder().encode(request)
            guard let physicalName,
                let remote = CFMessagePortCreateRemote(nil, physicalName as CFString)
            else {
                throw ExtensionPeerError.unavailable
            }
            var context = CFMessagePortContext(
                version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                retain: { pointer in
                    guard let pointer else { return nil }
                    return UnsafeRawPointer(
                        Unmanaged<ExtensionPeerCall>.fromOpaque(pointer).retain().toOpaque())
                },
                release: { pointer in
                    if let pointer { Unmanaged<ExtensionPeerCall>.fromOpaque(pointer).release() }
                }, copyDescription: nil)
            guard
                let receiver = CFMessagePortCreateLocal(
                    nil, request.reply as CFString,
                    { _, _, data, info in
                        guard let data, let info else { return nil }
                        Unmanaged<ExtensionPeerCall>.fromOpaque(info).takeUnretainedValue().receive(
                            data as Data)
                        return nil
                    }, &context, nil)
            else { throw ExtensionPeerError.unavailable }
            let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            timer.schedule(deadline: .now() + .milliseconds(250), repeating: .milliseconds(250))
            let deadline = ProcessInfo.processInfo.systemUptime + request.timeout
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                if !CFMessagePortIsValid(remote) {
                    self.stop(ExtensionPeerError.unavailable)
                } else if ProcessInfo.processInfo.systemUptime >= deadline {
                    self.stop(ExtensionPeerError.timedOut)
                }
            }
            timer.activate()
            let started = lock.withLock { () -> Bool in
                guard result == nil else { return false }
                self.receiver = receiver
                self.remote = remote
                self.timer = timer
                CFMessagePortSetDispatchQueue(receiver, .global(qos: .utility))
                return true
            }
            guard started else { timer.cancel(); CFMessagePortInvalidate(receiver); return }
            var acknowledgement: Unmanaged<CFData>?
            let code = CFMessagePortSendRequest(
                remote, 1, data as CFData, 1, 1, CFRunLoopMode.defaultMode.rawValue,
                &acknowledgement)
            let accepted = acknowledgement?.takeRetainedValue() as Data?
            guard code == kCFMessagePortSuccess else { throw ExtensionPeerError.unavailable }
            guard accepted == Data([1]) else {
                throw ExtensionPeerError.rejected(
                    "The extension could not accept this command. Try again when its current actions finish."
                )
            }
        } catch { stop(error) }
    }

    private func receive(_ data: Data) {
        guard data.count <= ExtensionPeerEndpoint.maximumMessageBytes,
            let response = try? JSONDecoder().decode(ExtensionPeerResponse.self, from: data),
            response.token == request.token
        else { stop(ExtensionPeerError.invalidRequest); return }
        if let payload = response.payload,
            payload.count <= ExtensionPeerEndpoint.maximumPayloadBytes
        {
            finish(.success(payload))
        } else {
            finish(
                .failure(
                    ExtensionPeerError.rejected(response.message ?? "The extension command failed.")
                ))
        }
    }

    @discardableResult
    private func finish(_ result: Result<Data, any Error>) -> Bool {
        let resources = lock.withLock {
            () -> (CheckedContinuation<Data, any Error>?, CFMessagePort?, DispatchSourceTimer?)? in
            guard self.result == nil else { return nil }
            self.result = result
            let resources = (continuation, receiver, timer)
            continuation = nil
            receiver = nil
            remote = nil
            timer = nil
            return resources
        }
        guard let resources else { return false }
        if let receiver = resources.1 { CFMessagePortInvalidate(receiver) }
        resources.2?.cancel()
        resources.0?.resume(with: result)
        return true
    }
}

@MainActor
public final class ExtensionPeerServer {
    public typealias Execute = @MainActor @Sendable (UUID, String, Data) async throws -> Data
    private struct Job {
        let request: ExtensionPeerRequest
        let task: Task<Void, Never>
        let monitor: Task<Void, Never>
    }
    private let endpoint: ExtensionPeerEndpoint
    private let execute: Execute
    private var port: CFMessagePort?
    private var jobs: [UUID: Job] = [:]
    private var registration: ExtensionPeerRegistrationLease?

    public init(endpoint: ExtensionPeerEndpoint, execute: @escaping Execute) {
        self.endpoint = endpoint
        self.execute = execute
    }

    public func start() throws {
        guard port == nil else { throw ExtensionPeerError.invalidRequest }
        let registration = try ExtensionPeerRegistrationLease(endpoint: endpoint)
        var context = CFMessagePortContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
            retain: { pointer in
                guard let pointer else { return nil }
                return UnsafeRawPointer(
                    Unmanaged<ExtensionPeerServer>.fromOpaque(pointer).retain().toOpaque())
            },
            release: { pointer in
                if let pointer { Unmanaged<ExtensionPeerServer>.fromOpaque(pointer).release() }
            }, copyDescription: nil)
        var reused = DarwinBoolean(false)
        guard
            let port = CFMessagePortCreateLocal(
                nil, registration.registration.physicalName as CFString,
                { _, kind, data, info in
                    guard let data, let info else { return nil }
                    return MainActor.assumeIsolated {
                        let server = Unmanaged<ExtensionPeerServer>.fromOpaque(info)
                            .takeUnretainedValue()
                        let response = server.receive(kind, data: data as Data)
                        return Unmanaged.passRetained(response as CFData)
                    }
                }, &context, &reused), !reused.boolValue
        else { throw ExtensionPeerError.unavailable }
        self.port = port
        self.registration = registration
        CFMessagePortSetDispatchQueue(port, .main)
        do { try registration.publish() } catch { shutdown(); throw error }
    }

    public func shutdown() {
        if let port { CFMessagePortInvalidate(port) }
        port = nil
        registration?.release()
        registration = nil
        let outstanding = jobs.values
        jobs.removeAll()
        for job in outstanding {
            job.task.cancel()
            job.monitor.cancel()
            Self.reply(
                job.request, payload: nil,
                message: ExtensionPeerError.unavailable.localizedDescription)
        }
    }

    private func receive(_ kind: Int32, data: Data) -> Data {
        if kind == 2, data.count == 36,
            let token = UUID(uuidString: String(decoding: data, as: UTF8.self)),
            let job = jobs.removeValue(forKey: token)
        {
            job.task.cancel()
            job.monitor.cancel()
            Self.reply(job.request, payload: nil, message: "The extension command was cancelled.")
            return Data([1])
        }
        guard kind == 1, data.count <= ExtensionPeerEndpoint.maximumMessageBytes,
            let request = try? JSONDecoder().decode(ExtensionPeerRequest.self, from: data),
            request.reply == "edith.extension.reply.\(getuid()).\(request.token.uuidString)",
            !request.command.isEmpty, request.command.utf8.count <= 256,
            !request.command.utf8.contains(0),
            request.payload.count <= ExtensionPeerEndpoint.maximumPayloadBytes,
            request.timeout.isFinite, request.timeout > 0, request.timeout <= 1_800,
            jobs[request.token] == nil, jobs.count < 8,
            let receiver = CFMessagePortCreateRemote(nil, request.reply as CFString),
            CFMessagePortIsValid(receiver)
        else { return Data([0]) }
        let task = Task { [weak self, execute] in
            do {
                let result = try await execute(request.token, request.command, request.payload)
                try Task.checkCancellation()
                guard result.count <= ExtensionPeerEndpoint.maximumPayloadBytes else {
                    throw ExtensionPeerError.invalidRequest
                }
                self?.complete(request, payload: result, message: nil)
            } catch { self?.complete(request, payload: nil, message: error.localizedDescription) }
        }
        let deadline = ProcessInfo.processInfo.systemUptime + request.timeout
        let monitor = Task { [weak self] in
            do {
                while true {
                    try await Task.sleep(for: .milliseconds(250))
                    if !CFMessagePortIsValid(receiver)
                        || ProcessInfo.processInfo.systemUptime >= deadline
                    {
                        guard let job = self?.jobs.removeValue(forKey: request.token) else {
                            return
                        }
                        job.task.cancel()
                        Self.reply(
                            request, payload: nil, message: "The extension command was cancelled.")
                        return
                    }
                }
            } catch {}
        }
        jobs[request.token] = Job(request: request, task: task, monitor: monitor)
        return Data([1])
    }

    private func complete(_ request: ExtensionPeerRequest, payload: Data?, message: String?) {
        guard let job = jobs.removeValue(forKey: request.token) else { return }
        job.monitor.cancel()
        Self.reply(request, payload: payload, message: message)
    }

    private nonisolated static func reply(
        _ request: ExtensionPeerRequest, payload: Data?, message: String?
    ) {
        DispatchQueue.global(qos: .utility).async {
            guard let remote = CFMessagePortCreateRemote(nil, request.reply as CFString),
                let data = try? JSONEncoder().encode(
                    ExtensionPeerResponse(
                        token: request.token, payload: payload,
                        message: message.map { String($0.prefix(2_048)) }))
            else { return }
            _ = CFMessagePortSendRequest(remote, 1, data as CFData, 1, 0, nil, nil)
        }
    }
}
