import Darwin
import DatabaseCore
import EdithExtensionSupport
import EdithExtensionUI
import Foundation

enum DatabaseMachineForwardRoutingError: LocalizedError, Equatable {
    case ambiguousPort(Int)
    case machineUnavailable(String)
    case forwardUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .ambiguousPort(let port):
            "Several saved machine forwards use local port \(port). Choose a unique port."
        case .machineUnavailable(let name):
            "The machine for \(name) is unavailable."
        case .forwardUnavailable(let name):
            "The saved machine forward for \(name) could not be opened."
        }
    }
}

enum DatabaseMachineForwardRouteResolver {
    static func ports(_ endpoints: [DatabaseNetworkEndpoint]) -> [Int] {
        Array(Set(endpoints.filter {
            ["localhost", "127.0.0.1", "::1"].contains($0.host.lowercased())
        }.map(\.port.value))).sorted()
    }
}

@MainActor
enum DatabaseMachineForwardRouter {
    static func prepare(_ connection: DatabaseConnectionSummary) async throws {
        let ports = DatabaseMachineForwardRouteResolver.ports(connection.networkEndpoints)
        var missing: [Int] = []
        for port in ports.sorted() {
            if !(await DatabaseLoopbackPortProbe.isReachable(port)) { missing.append(port) }
        }
        guard !missing.isEmpty, let endpoint = ExtensionPeerEndpoint.current(owner: "machines")
        else { return }
        _ = try await endpoint.invoke(
            "machines.forward.prepare", payload: JSONEncoder().encode(Prepare(ports: missing)))
    }

    private struct Prepare: Encodable { let ports: [Int] }
}

private enum DatabaseLoopbackPortProbe {
    static func isReachable(_ port: Int) async -> Bool {
        await Task.detached(priority: .utility) {
            probe(port)
        }.value
    }

    private static func probe(_ port: Int) -> Bool {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { Darwin.close(descriptor) }

        let flags = Darwin.fcntl(descriptor, F_GETFL, 0)
        guard flags >= 0, Darwin.fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            return false
        }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(
                    descriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if connected == 0 { return true }
        guard errno == EINPROGRESS else { return false }

        var pollDescriptor = pollfd(
            fd: descriptor,
            events: Int16(POLLOUT),
            revents: 0)
        guard Darwin.poll(&pollDescriptor, 1, 250) > 0 else { return false }
        var socketError: Int32 = 0
        var socketErrorSize = socklen_t(MemoryLayout<Int32>.size)
        guard
            Darwin.getsockopt(
                descriptor,
                SOL_SOCKET,
                SO_ERROR,
                &socketError,
                &socketErrorSize) == 0
        else { return false }
        return socketError == 0
    }
}
