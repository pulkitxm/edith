import Foundation
import ServiceManagement
import Testing
@testable import EdithExtensionSupport

@MainActor private final class PrivilegedTransportFixture: ExtensionPrivilegedTransport {
    let invalidated: @MainActor () -> Void
    var activations = 0
    var releases = 0
    var refusesRelease = false
    var closed = false
    init(invalidated: @escaping @MainActor () -> Void) { self.invalidated = invalidated }
    func activate(source: URL, owner: String, version: String) async throws { activations += 1 }
    func invoke(_ command: String, payload: Data) async throws -> Data { payload }
    func release() async throws {
        releases += 1
        if refusesRelease { throw ExtensionPeerError.rejected("Restore denied") }
    }
    func invalidate() { closed = true; invalidated() }
}

@Suite @MainActor struct ExtensionPrivilegedClientTests {
    @Test func containedConnectionsNeverQueryOrRegisterAContainingAppService() async throws {
        var queries = 0
        var channels: [PrivilegedTransportFixture] = []
        let client = ExtensionPrivilegedClient(
            owner: "sample", source: URL(fileURLWithPath: "/synthetic/payload.bundle"),
            version: "1.0.0", mode: .connectOnly(hostIdentifier: "com.example.host"),
            status: {
                queries += 1; return .requiresApproval
            },
            connect: { invalidated in
                let created = PrivilegedTransportFixture(invalidated: invalidated)
                channels.append(created); return created
            })
        #expect(client.status == .notFound)
        #expect(throws: ExtensionPeerError.self) { try client.requestApproval() }
        #expect(try await client.invoke("apply", payload: Data()).isEmpty)
        #expect(client.status == .enabled && queries == 0)
        channels[0].invalidate()
        try await client.release()
        #expect(channels.count == 2 && channels[1].releases == 1 && channels[1].closed)
        #expect(client.status == .notFound && queries == 0)
    }

    @Test(arguments: ["", "com..host", "com.host\"", "com.host/other", "com.host\n"])
    func invalidContainingHostIdentifiersNeverConnect(identifier: String) async {
        var connections = 0
        let client = ExtensionPrivilegedClient(
            owner: "sample", source: URL(fileURLWithPath: "/synthetic/payload.bundle"),
            version: "1.0.0", mode: .connectOnly(hostIdentifier: identifier),
            status: { .enabled },
            connect: { invalidated in
                connections += 1; return PrivilegedTransportFixture(invalidated: invalidated)
            })
        await #expect(throws: ExtensionPeerError.self) {
            try await client.invoke("apply", payload: Data())
        }
        #expect(connections == 0)
    }

    @Test func disconnectedLeaseRequiresAConfirmedRestorationBeforeReleaseCompletes() async throws {
        var channels: [PrivilegedTransportFixture] = []
        let client = ExtensionPrivilegedClient(
            owner: "sample", source: URL(fileURLWithPath: "/synthetic/payload.bundle"),
            version: "1.0.0", status: { .enabled },
            connect: { invalidated in
                let created = PrivilegedTransportFixture(invalidated: invalidated);
                channels.append(created); return created
            })
        let bytes = Data("synthetic".utf8)
        #expect(try await client.invoke("apply", payload: bytes) == bytes)
        channels[0].invalidate()
        try await client.release()
        #expect(channels.count == 2)
        #expect(channels[1].activations == 1 && channels[1].releases == 1 && channels[1].closed)
        try await client.release()
        #expect(channels.count == 2)
    }

    @Test func failedRestorationKeepsTheLeaseForRetryAndIgnoresOldInvalidations() async throws {
        var channels: [PrivilegedTransportFixture] = []
        let client = ExtensionPrivilegedClient(
            owner: "sample", source: URL(fileURLWithPath: "/synthetic/payload.bundle"),
            version: "1.0.0", status: { .enabled },
            connect: { invalidated in
                let created = PrivilegedTransportFixture(invalidated: invalidated);
                channels.append(created); return created
            })
        _ = try await client.invoke("apply", payload: Data())
        channels[0].invalidate()
        _ = try await client.invoke("apply", payload: Data())
        channels[0].invalidated()
        channels[1].refusesRelease = true
        await #expect(throws: ExtensionPeerError.self) { try await client.release() }
        #expect(!channels[1].closed)
        #expect(try await client.invoke("status", payload: Data()).isEmpty)
        channels[1].refusesRelease = false
        try await client.release()
        #expect(channels.count == 2 && channels[1].releases == 2 && channels[1].closed)
    }

    @Test func unapprovedServicesAndOversizedCommandsNeverConnect() async throws {
        var connected = false
        let client = ExtensionPrivilegedClient(
            owner: "sample", source: URL(fileURLWithPath: "/synthetic/payload.bundle"),
            version: "1.0.0", status: { .requiresApproval },
            connect: { invalidated in
                connected = true; return PrivilegedTransportFixture(invalidated: invalidated)
            })
        await #expect(throws: ExtensionPeerError.self) {
            try await client.invoke("apply", payload: Data())
        }
        await #expect(throws: ExtensionPeerError.self) {
            try await client.invoke("apply", payload: Data(repeating: 1, count: 32_769))
        }
        try await client.release()
        #expect(!connected)
    }
}
