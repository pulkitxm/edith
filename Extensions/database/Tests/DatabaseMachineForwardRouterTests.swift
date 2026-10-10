import DatabaseCore
import Testing
@testable import DatabaseExtension

@Suite struct DatabaseMachineForwardRouterTests {
    @Test func selectsUniqueLoopbackPortsForMachinePeer() throws {
        let endpoints = try [
            DatabaseNetworkEndpoint(host: "localhost", port: DatabasePort(5432)),
            DatabaseNetworkEndpoint(host: "127.0.0.1", port: DatabasePort(5432)),
            DatabaseNetworkEndpoint(host: "::1", port: DatabasePort(6379)),
            DatabaseNetworkEndpoint(host: "db.example.test", port: DatabasePort(3306)),
        ]
        #expect(DatabaseMachineForwardRouteResolver.ports(endpoints) == [5432, 6379])
    }
}
