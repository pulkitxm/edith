import Foundation
import Testing
@testable import EdithExtensionSupport

@Suite(.serialized) struct ExtensionPeerLatencyTests {
    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString)

    @MainActor private func makeServer() throws -> (ExtensionPeerEndpoint, ExtensionPeerServer) {
        let endpoint = try ExtensionPeerEndpoint(
            namespace: UUID().uuidString, owner: "latency", directory: directory)
        let server = ExtensionPeerServer(endpoint: endpoint) { _, command, payload in
            if command == "slow" { try await Task.sleep(for: .seconds(5)) }
            return payload
        }
        return (endpoint, server)
    }

    private func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1_000
            + Double(duration.components.attoseconds) / 1e15
    }

    private func measure(_ endpoint: ExtensionPeerEndpoint, samples: Int) async throws -> Double {
        var timings: [Double] = []
        for _ in 0..<samples {
            let start = ContinuousClock.now
            let reply = try await endpoint.invoke("snapshot", payload: Data("{}".utf8))
            timings.append(milliseconds(ContinuousClock.now - start))
            #expect(reply == Data("{}".utf8))
        }
        return timings.sorted()[timings.count / 2]
    }

    @MainActor @Test func idleSnapshotReadIsFast() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let (endpoint, server) = try makeServer()
        try server.start()
        defer { server.shutdown() }
        _ = try await measure(endpoint, samples: 1)
        let median = try await measure(endpoint, samples: 25)
        print("LATENCY idle median ms", median)
        #expect(median < 50)
    }

    @MainActor @Test(arguments: [1, 4, 7, 8, 12]) func snapshotReadIgnoresSlowRequests(
        slowCount: Int
    ) async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let (endpoint, server) = try makeServer()
        try server.start()
        defer { server.shutdown() }
        _ = try await measure(endpoint, samples: 1)
        let slow = (0..<slowCount).map { _ in
            Task { try? await endpoint.invoke("slow", timeout: 30) }
        }
        try await Task.sleep(for: .milliseconds(300))
        let median = try await measure(endpoint, samples: 15)
        print("LATENCY slow=\(slowCount) median ms", median)
        for task in slow { task.cancel() }
        for task in slow { _ = await task.value }
        await server.shutdownAndWait()
        #expect(median < 50)
    }

    @MainActor @Test(arguments: [8, 12, 24]) func concurrentRequestsAreNotRejected(
        count: Int
    ) async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let (endpoint, server) = try makeServer()
        try server.start()
        defer { server.shutdown() }
        let start = ContinuousClock.now
        let results = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<count {
                group.addTask {
                    (try? await endpoint.invoke("snapshot", payload: Data("{}".utf8))) != nil
                }
            }
            var ok = 0
            for await success in group where success { ok += 1 }
            return ok
        }
        print(
            "LATENCY concurrent=\(count) ok=\(results) ms",
            milliseconds(ContinuousClock.now - start))
        #expect(results == count)
    }
}
