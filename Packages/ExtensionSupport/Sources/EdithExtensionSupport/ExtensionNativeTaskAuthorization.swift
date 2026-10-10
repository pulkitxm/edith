import Darwin
import Foundation

public enum ExtensionNativeTaskAuthorization {
    public static func request(parent: Int32) throws -> Data {
        guard let owner = ProcessInfo.processInfo.environment["EDITH_EXTENSION_ID"],
            let endpoint = ExtensionPeerEndpoint.current(owner: owner)
        else {
            throw ExtensionPeerError.unavailable
        }
        guard let token = ProcessInfo.processInfo.environment["EDITH_EXTENSION_NATIVE_TOKEN"],
            token.utf8.count == 72
        else { throw ExtensionPeerError.unavailable }
        return try request(endpoint: endpoint, parent: parent, token: token)
    }

    static func request(endpoint: ExtensionPeerEndpoint, parent: Int32, token: String) throws
        -> Data
    {
        guard parent > 1, token.utf8.count == 72,
            let registration = ExtensionPeerRegistration.read(
                at: endpoint.registrationURL, logicalName: endpoint.name),
            registration.process.pid == parent
        else { throw ExtensionPeerError.unavailable }
        let path = ExtensionPeerSocket.path(registration.physicalName)
        var address = sockaddr_un()
        guard path.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw ExtensionPeerError.invalidRequest
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: Array(path.utf8) + [0])
        }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw ExtensionPeerError.unavailable }
        defer { close(descriptor) }
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        guard
            setsockopt(
                descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)
            ) == 0,
            setsockopt(
                descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)
            ) == 0,
            withUnsafePointer(
                to: &address,
                { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                    }
                }) == 0
        else { throw ExtensionPeerError.unavailable }
        var server: Int32 = 0
        var size = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERPID, &server, &size) == 0,
            server == parent, registration.process.isAlive
        else { throw ExtensionPeerError.unavailable }
        let payload = try JSONSerialization.data(withJSONObject: ["pid": getpid(), "token": token])
        let request = ExtensionPeerRequest(
            token: UUID(), command: "extension.native.authorize", payload: payload, timeout: 5)
        let frame = try ExtensionPeerFrame.encode(request)
        try frame.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(
                    descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw ExtensionPeerError.unavailable }
                offset += count
            }
        }
        let header = try read(4, descriptor: descriptor)
        let count = header.reduce(0) { ($0 << 8) | Int($1) }
        guard (1...32_768).contains(count) else { throw ExtensionPeerError.invalidRequest }
        let response = try JSONDecoder().decode(
            ExtensionPeerResponse.self, from: read(count, descriptor: descriptor))
        guard response.token == request.token, response.message == nil,
            let configuration = response.payload, !configuration.isEmpty,
            configuration.count <= 16_384, registration.process.isAlive
        else {
            throw ExtensionPeerError.unavailable
        }
        return configuration
    }

    private static func read(_ count: Int, descriptor: Int32) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        try bytes.withUnsafeMutableBytes { buffer in
            var offset = 0
            while offset < count {
                let received = Darwin.read(
                    descriptor, buffer.baseAddress!.advanced(by: offset), count - offset)
                if received < 0, errno == EINTR { continue }
                guard received > 0 else { throw ExtensionPeerError.unavailable }
                offset += received
            }
        }
        return Data(bytes)
    }
}
