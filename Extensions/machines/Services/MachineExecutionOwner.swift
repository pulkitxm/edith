import Foundation

public final class MachineExecutionOwner: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    private var streams: [ObjectIdentifier: SSHLineStream] = [:]

    public init() {}

    public func start(_ stream: SSHLineStream) throws {
        try lock.withLock {
            guard !stopped else { throw CancellationError() }
            streams[ObjectIdentifier(stream)] = stream
            do { try stream.start() } catch {
                streams.removeValue(forKey: ObjectIdentifier(stream))
                throw error
            }
        }
    }

    public func release(_ stream: SSHLineStream) {
        _ = lock.withLock { streams.removeValue(forKey: ObjectIdentifier(stream)) }
    }

    public func shutdown() async {
        let retained = lock.withLock {
            stopped = true
            let retained = Array(streams.values)
            streams.removeAll()
            return retained
        }
        for stream in retained { stream.cancel() }
        for stream in retained { _ = await stream.waitForExit(); await stream.waitForProcessExit() }
    }
}
