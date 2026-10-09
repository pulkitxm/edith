import EdithExtensionSupport
import Foundation
import Testing
@testable import UsageExtension

@Suite struct UsageMachinesPeerTests {
    actor Transport {
        let data: Data
        let corrupt: Bool
        var releases = 0
        init(data: Data, corrupt: Bool = false) { self.data = data; self.corrupt = corrupt }
        func invoke(_ command: String, payload: Data) throws -> Data {
            switch command {
            case "machines.usage.collect":
                return try JSONEncoder().encode(
                    UsageMachinesPeer.Receipt(
                        collectionID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                        byteCount: data.count,
                        sha256: corrupt
                            ? String(repeating: "0", count: 64) : UsageMachinesPeer.hash(data),
                        generatedAt: "2026-10-09T12:00:00Z"))
            case "machines.usage.result":
                let request = try JSONSerialization.jsonObject(with: payload) as! [String: Any]
                let offset = request["offset"] as! Int
                let end = min(data.count, offset + 262_144)
                return try JSONEncoder().encode(
                    UsageMachinesPeer.Chunk(
                        offset: offset, data: data.subdata(in: offset..<end),
                        finished: end == data.count))
            case "machines.usage.cancel": releases += 1; return Data("{}".utf8)
            default: throw ExtensionPeerError.invalidRequest
            }
        }
    }

    @Test func chunkedResultIsValidatedAndReleasedBeforeReturning() async throws {
        let data = try fixture()
        let transport = Transport(data: data)
        let peer = UsageMachinesPeer(
            active: { true }, invoke: { try await transport.invoke($0, payload: $1) })
        #expect(try await peer.collect(machineID: UUID(), force: false) == data)
        #expect(await transport.releases == 1)
    }

    @Test func checksumFailureAndInactivePeersCannotPublishData() async throws {
        let transport = Transport(data: try fixture(), corrupt: true)
        let peer = UsageMachinesPeer(
            active: { true }, invoke: { try await transport.invoke($0, payload: $1) })
        await #expect(throws: ExtensionPeerError.self) {
            _ = try await peer.collect(machineID: UUID(), force: false)
        }
        #expect(await transport.releases == 1)
        let inactive = UsageMachinesPeer(
            active: { false },
            invoke: { _, _ in
                Issue.record("Inactive peer invoked"); return Data()
            })
        await #expect(throws: ExtensionPeerError.self) {
            _ = try await inactive.collect(machineID: UUID(), force: false)
        }
    }

    @Test func remoteSourcesAreBoundToRegistryMachineIdentity() throws {
        let machine = Machine(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!, name: "Sample machine",
            host: "sample.invalid")
        let data = try UsageMachinesPeer.canonicalized(fixture(), machine: machine)
        #expect(UsageHistory.isValidDocument(data))
        let value = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(
            value["sources"] as? [String] == ["machine:22222222-2222-2222-2222-222222222222:codex"])
    }

    private func fixture() throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 8, "generatedAt": "2026-10-09T12:00:00Z", "sources": ["codex"],
            "defaultSources": ["codex"], "sourceMeta": ["codex": ["label": "Sample"]],
            "sessions": [], "daily": [],
            "totals": [
                "cost": 0, "tokens": 0, "inputTokens": 0, "outputTokens": 0,
                "cacheCreationTokens": 0, "cacheReadTokens": 0, "bySource": [:],
            ], "padding": String(repeating: "x", count: 300_000),
        ])
    }
}
