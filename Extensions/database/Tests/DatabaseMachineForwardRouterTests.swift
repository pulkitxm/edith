import DatabaseCore
import EdithExtensionSupport
import Foundation
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

    @Test func plainLocalDatabasesWithoutASavedForwardFallThroughSilently() async throws {
        let endpoints = try [DatabaseNetworkEndpoint(host: "localhost", port: DatabasePort(5432))]
        try await DatabaseMachineForwardRouter.prepare(
            endpoints: endpoints,
            forwards: { [.init(localPort: 6379, name: "Other")] },
            reachable: { _ in
                Issue.record("must not probe"); return false
            },
            start: { _ in Issue.record("must not start") })
    }

    @Test func severalMatchingForwardsAreAmbiguous() async throws {
        let endpoints = try [
            DatabaseNetworkEndpoint(host: "localhost", port: DatabasePort(5432)),
            DatabaseNetworkEndpoint(host: "127.0.0.1", port: DatabasePort(6379)),
        ]
        await #expect(throws: DatabaseMachineForwardRoutingError.ambiguousPort(5432)) {
            try await DatabaseMachineForwardRouter.prepare(
                endpoints: endpoints,
                forwards: {
                    [.init(localPort: 5432, name: "A"), .init(localPort: 6379, name: "B")]
                },
                reachable: { _ in false }, start: { _ in })
        }
    }

    @Test func reachablePortsAreLeftAloneAndOnlyTheMatchedForwardStarts() async throws {
        let endpoints = try [DatabaseNetworkEndpoint(host: "::1", port: DatabasePort(5432))]
        let saved = [
            DatabaseSavedMachineForward(localPort: 5432, name: "Primary"),
            .init(localPort: 9999, name: "Unrelated"),
        ]
        try await DatabaseMachineForwardRouter.prepare(
            endpoints: endpoints, forwards: { saved }, reachable: { _ in true },
            start: { _ in Issue.record("must not start") })
        let started = Started()
        try await DatabaseMachineForwardRouter.prepare(
            endpoints: endpoints, forwards: { saved }, reachable: { _ in false },
            start: { started.ports.append($0) })
        #expect(started.ports == [5432])
    }

    @Test func peerFailuresMapToTheOriginalMessages() async throws {
        let endpoints = try [DatabaseNetworkEndpoint(host: "localhost", port: DatabasePort(5432))]
        let saved = [DatabaseSavedMachineForward(localPort: 5432, name: "Primary")]
        await #expect(throws: DatabaseMachineForwardRoutingError.machineUnavailable("Primary")) {
            try await DatabaseMachineForwardRouter.prepare(
                endpoints: endpoints, forwards: { saved }, reachable: { _ in false },
                start: { _ in
                    throw ExtensionPeerError.rejected("Choose an available saved machine.")
                })
        }
        await #expect(throws: DatabaseMachineForwardRoutingError.forwardUnavailable("Primary")) {
            try await DatabaseMachineForwardRouter.prepare(
                endpoints: endpoints, forwards: { saved }, reachable: { _ in false },
                start: { _ in throw ExtensionPeerError.unavailable })
        }
    }
}

private final class Started: @unchecked Sendable { var ports: [Int] = [] }
