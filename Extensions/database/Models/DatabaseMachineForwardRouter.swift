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

struct DatabaseSavedMachineForward: Decodable, Equatable {
    let localPort: Int
    let name: String
}

enum DatabaseMachineForwardRouteResolver {
    static func ports(_ endpoints: [DatabaseNetworkEndpoint]) -> [Int] {
        Array(
            Set(
                endpoints.filter {
                    loopbackHosts.contains($0.host.lowercased())
                }.map(\.port.value))
        ).sorted()
    }

    static func resolve(
        endpoints: [DatabaseNetworkEndpoint],
        forwards: [DatabaseSavedMachineForward]
    ) throws -> DatabaseSavedMachineForward? {
        let ports = Set(ports(endpoints))
        guard !ports.isEmpty else { return nil }
        let matches = forwards.filter { ports.contains($0.localPort) }
        guard matches.count <= 1 else {
            throw DatabaseMachineForwardRoutingError.ambiguousPort(matches[0].localPort)
        }
        return matches.first
    }

    private static let loopbackHosts: Set<String> = ["127.0.0.1", "localhost", "::1"]
}

@MainActor
enum DatabaseMachineForwardRouter {
    static func prepare(_ connection: DatabaseConnectionSummary) async throws {
        guard !DatabaseMachineForwardRouteResolver.ports(connection.networkEndpoints).isEmpty,
            let endpoint = ExtensionPeerEndpoint.current(owner: "machines")
        else { return }
        try await prepare(
            endpoints: connection.networkEndpoints,
            forwards: {
                let bytes = try await endpoint.invoke(
                    "machines.forward.list", payload: Data("{}".utf8))
                return try JSONDecoder().decode(SavedForwards.self, from: bytes).forwards
            },
            reachable: { await DatabaseLoopbackPortProbe.isReachable($0) },
            start: { port in
                _ = try await endpoint.invoke(
                    "machines.forward.prepare",
                    payload: JSONEncoder().encode(Prepare(ports: [port])))
            })
    }

    static func prepare(
        endpoints: [DatabaseNetworkEndpoint],
        forwards: () async throws -> [DatabaseSavedMachineForward],
        reachable: (Int) async -> Bool,
        start: (Int) async throws -> Void
    ) async throws {
        guard
            let forward = try DatabaseMachineForwardRouteResolver.resolve(
                endpoints: endpoints, forwards: try await forwards())
        else { return }
        if await reachable(forward.localPort) { return }
        do {
            try await start(forward.localPort)
        } catch is CancellationError {
            throw CancellationError()
        } catch ExtensionPeerError.rejected(_) {
            throw DatabaseMachineForwardRoutingError.machineUnavailable(forward.name)
        } catch {
            throw DatabaseMachineForwardRoutingError.forwardUnavailable(forward.name)
        }
    }

    private struct Prepare: Encodable { let ports: [Int] }
    private struct SavedForwards: Decodable { let forwards: [DatabaseSavedMachineForward] }
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
