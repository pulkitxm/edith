import EdithDatabase
import EdithKit
import Foundation
import Testing

@testable import Edith

@Suite struct DatabaseMachineForwardRouterTests {
    @Test func resolvesSavedForwardForLoopbackDatabaseEndpoint() throws {
        let machineID = UUID()
        let forward = PortForward(
            machineID: machineID,
            localPort: 55_432,
            remoteHost: "127.0.0.1",
            remotePort: 5_432,
            title: "PostgreSQL")
        let endpoint = DatabaseNetworkEndpoint(
            host: "localhost",
            port: try DatabasePort(55_432))

        let resolved = try DatabaseMachineForwardRouteResolver.resolve(
            endpoints: [endpoint],
            forwards: [forward])

        #expect(resolved == forward)
    }

    @Test func ignoresRemoteDatabaseEndpoints() throws {
        let forward = PortForward(
            machineID: UUID(),
            localPort: 5_432,
            remotePort: 5_432)
        let endpoint = DatabaseNetworkEndpoint(
            host: "db.example.com",
            port: try DatabasePort(5_432))

        let resolved = try DatabaseMachineForwardRouteResolver.resolve(
            endpoints: [endpoint],
            forwards: [forward])

        #expect(resolved == nil)
    }

    @Test func rejectsAmbiguousLoopbackForwards() throws {
        let endpoint = DatabaseNetworkEndpoint(
            host: "127.0.0.1",
            port: try DatabasePort(55_432))
        let forwards = [
            PortForward(machineID: UUID(), localPort: 55_432, remotePort: 5_432),
            PortForward(machineID: UUID(), localPort: 55_432, remotePort: 5_432),
        ]

        #expect(throws: DatabaseMachineForwardRoutingError.ambiguousPort(55_432)) {
            try DatabaseMachineForwardRouteResolver.resolve(
                endpoints: [endpoint],
                forwards: forwards)
        }
    }
}
