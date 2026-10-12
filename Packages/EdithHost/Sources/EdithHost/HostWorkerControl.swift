import EdithHostCore
import Foundation

final class HostWorkerControl: @unchecked Sendable {
    private final class Registration {
        let resource: HostWorkerProcessGroup
        let completion = DispatchSemaphore(value: 0)
        var accepted = false

        init(_ resource: HostWorkerProcessGroup) { self.resource = resource }
    }

    private let lock = NSLock()
    private let handle: FileHandle
    private var frames = HostWorkerFrames()
    private var registrations: [Int32: Registration] = [:]
    private var closed = false

    init(descriptor: Int32) {
        handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    func send<T: Encodable>(_ value: T) throws {
        let bytes = try HostWorkerFrames.encode(value)
        try lock.withLock {
            guard !closed else { throw HostWorkerError.exited }
            try handle.write(contentsOf: bytes)
        }
    }

    func register(_ resource: HostWorkerProcessGroup) throws {
        guard resource.kind == "processGroup", resource.registered, resource.pid > 1 else {
            throw HostWorkerError.invalidResponse
        }
        let registration = Registration(resource)
        let bytes = try HostWorkerFrames.encode(resource)
        do {
            try lock.withLock {
                guard !closed else { throw HostWorkerError.exited }
                guard registrations[resource.pid] == nil else {
                    throw HostWorkerError.invalidResponse
                }
                registrations[resource.pid] = registration
                try handle.write(contentsOf: bytes)
            }
            let completed = registration.completion.wait(timeout: .now() + 2) == .success
            try lock.withLock {
                registrations.removeValue(forKey: resource.pid)
                guard completed else { throw HostWorkerError.timedOut }
                guard !closed, registration.accepted else { throw HostWorkerError.invalidResponse }
            }
        } catch {
            invalidate()
            throw error
        }
    }

    func receive(_ bytes: Data) throws -> [Data] {
        do {
            return try lock.withLock {
                guard !closed, !bytes.isEmpty else { throw HostWorkerError.exited }
                var requests: [Data] = []
                for frame in try frames.append(bytes) {
                    if let resource = try? JSONDecoder().decode(
                        HostWorkerProcessGroup.self, from: frame), resource.kind == "processGroup"
                    {
                        guard resource.registered,
                            let registration = registrations[resource.pid], !registration.accepted,
                            registration.resource.generation == resource.generation
                        else { throw HostWorkerError.invalidResponse }
                        registration.accepted = true
                        registration.completion.signal()
                    } else {
                        requests.append(frame)
                    }
                }
                return requests
            }
        } catch {
            invalidate()
            throw error
        }
    }

    func invalidate() {
        lock.withLock {
            closed = true
            for registration in registrations.values { registration.completion.signal() }
        }
    }

    func close() throws {
        invalidate()
        try lock.withLock { try handle.close() }
    }
}
