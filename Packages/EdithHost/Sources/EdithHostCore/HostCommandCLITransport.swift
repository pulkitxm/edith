import Darwin
import Foundation

public enum HostCommandCLITransport {
    public static func invoke(_ request: HostCLIRequest, identity: HostIdentity) async throws
        -> Data
    {
        try request.validate()
        try Task.checkCancellation()
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw HostCLIError.unavailable }
        let connection = HostCLIConnection(descriptor)
        let cancellation = HostCommandCLICancellation()
        return try await withTaskCancellationHandler {
            let work = Task.detached {
                defer { connection.close() }
                try cancellation.check()
                try connection.configure(timeout: request.timeout + 2)
                var address = try HostCLITransport.address(
                    HostCLITransport.socketPath(identity: identity))
                let connected = withUnsafePointer(to: &address) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                    }
                }
                guard connected == 0 else { throw HostCLIError.unavailable }
                try cancellation.check()
                let peer = try HostCLIProcess.peer(descriptor)
                try connection.write(request.encoded(), limit: HostCLITransport.maximumRequest)
                try cancellation.check()
                let response = try HostCLIResponse.decoded(
                    connection.read(limit: HostCLITransport.maximumFrame))
                guard HostCLIProcess.read(peer.pid) == peer else { throw HostCLIError.unavailable }
                if let error = response.error {
                    if response.exitCode == 4 { throw HostCLIError.timedOut }
                    if response.exitCode == 2 { throw HostCLIError.usage(error) }
                    throw HostCLIError.rejected(error)
                }
                guard response.exitCode == 0, let data = response.payload,
                    data.count <= 8 * 1024 * 1024,
                    (try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed))
                        != nil
                else { throw HostCLIError.rejected("Invalid host command response.") }
                return data
            }
            do {
                let result = try await work.value
                try Task.checkCancellation()
                return result
            } catch {
                try Task.checkCancellation()
                throw error
            }
        } onCancel: {
            cancellation.cancel()
            connection.cancel()
        }
    }
}

private final class HostCommandCLICancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.withLock { cancelled = true } }
    func check() throws {
        if lock.withLock({ cancelled }) { throw CancellationError() }
    }
}
