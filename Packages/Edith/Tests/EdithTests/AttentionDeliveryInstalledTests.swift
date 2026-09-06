import Foundation
import Testing

@testable import EdithHelper
@testable import EdithKit

@MainActor @Suite struct AttentionDeliveryInstalledTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["EDITH_ATTENTION_DELIVERY_LIVE"] == "1"))
    func installedDaemonReconnectPreservesAndDeduplicatesTheHelperQueue() async throws {
        let environment = ProcessInfo.processInfo.environment
        let rootPath = try #require(environment["EDITH_ATTENTION_DELIVERY_ROOT"])
        let service = try #require(environment["EDITH_AGENT_MACH_SERVICE"])
        let stage = try #require(environment["EDITH_ATTENTION_DELIVERY_STAGE"])
        let instant = try #require(
            environment["EDITH_ATTENTION_DELIVERY_INSTANT"].flatMap(Double.init))
        let root = URL(fileURLWithPath: rootPath).resolvingSymlinksInPath()
        let file = AttentionDeliverySpool.defaultFile.resolvingSymlinksInPath()
        guard root.lastPathComponent.hasPrefix("edith-attention-delivery-"),
            service.hasPrefix("com.pulkit.edith.test."), instant.isFinite,
            environment["EDITH_SHARED_DEFAULTS_SUITE"] == service + ".defaults",
            environment["EDITH_HELPER_DEFAULTS_SUITE"] == service + ".helper",
            environment["EDITH_PROVIDER_KEYCHAIN_SERVICE"] == service + ".provider-credentials",
            environment["EDITH_DATA_ROOT"].map({
                URL(fileURLWithPath: $0).resolvingSymlinksInPath()
            })
                == root.appendingPathComponent("data"),
            file.path.hasPrefix(root.appendingPathComponent("data").path + "/")
        else { throw AgentError(.refused, "A private Attention delivery fixture is required.") }
        let now = Date(timeIntervalSince1970: instant)
        func sample(_ offset: TimeInterval) -> AttentionHeartbeatSample {
            AttentionHeartbeatSample(
                event: AttentionEvent(
                    startedAt: now.addingTimeInterval(offset), duration: 5,
                    source: .application, appName: "Delivery verification",
                    bundleID: "com.example.attention-delivery"),
                processID: 0, captureWindowTitle: false)
        }
        let client = AgentClient()
        switch stage {
        case "offline":
            let writer = AttentionHeartbeatWriter(
                retryDelay: .seconds(3600), prepare: { $0.event },
                deliver: { try await AttentionDeliveryClient.deliver($0, client: client) })
            writer.submit(sample(-60))
            writer.submit(sample(-55))
            await writer.flush()
            await writer.stop()
            #expect(writer.isStopped)
            let health = try await writer.health()
            #expect(health.pendingEvents == 2)
            #expect(health.lastFailure != nil)
            try await saveHealth(stage, writer: writer, root: root)
        case "recover":
            let before = try await AttentionDeliverySpool(file: file).health()
            #expect(before.pendingEvents == 2)
            let ambiguity = AttentionDeliveryAmbiguity()
            let writer = AttentionHeartbeatWriter(
                retryDelay: .milliseconds(100), prepare: { $0.event },
                deliver: { request in
                    try await AttentionDeliveryClient.deliver(request, client: client)
                    if await ambiguity.first() {
                        throw AgentError(.unavailable, "Reply was not observed.")
                    }
                })
            await writer.flush()
            #expect(try await writer.health().pendingEvents == 2)
            let deadline = ContinuousClock.now.advanced(by: .seconds(15))
            while try await writer.health().pendingEvents > 0 {
                guard ContinuousClock.now < deadline else {
                    await writer.stop()
                    throw AgentError(.failed, "The saved queue did not drain after reconnect.")
                }
                try await Task.sleep(for: .milliseconds(25))
            }
            await writer.stop()
            let result = try await read(now: now, client: client)
            #expect(result.events.count == 1)
            #expect(result.events.first?.duration == 10)
            try await saveHealth(stage, writer: writer, root: root)
        case "restart":
            let before = try await AttentionDeliverySpool(file: file).health()
            #expect(before.pendingEvents == 0)
            #expect(before.committedSequence == 2)
            let writer = AttentionHeartbeatWriter(
                prepare: { $0.event },
                deliver: { try await AttentionDeliveryClient.deliver($0, client: client) })
            writer.submit(sample(-50))
            await writer.flush()
            await writer.stop()
            let result = try await read(now: now, client: client)
            #expect(result.events.count == 1)
            #expect(result.events.first?.duration == 15)
            #expect(try await writer.health().committedSequence == 3)
            try await saveHealth(stage, writer: writer, root: root)
        default:
            throw AgentError(.refused, "Unknown private Attention delivery stage.")
        }
    }

    private func read(now: Date, client: AgentClient) async throws -> AttentionRangeResponse {
        let request = AttentionRangeRequest(from: now.addingTimeInterval(-65), to: now)
        let data = try await client.performInternalAsync(
            AttentionOperation.range, payload: AgentPayload.encode(request))
        return try AgentPayload.decode(AttentionRangeResponse.self, from: data)
    }

    private func saveHealth(
        _ stage: String, writer: AttentionHeartbeatWriter, root: URL
    ) async throws {
        let health = try await writer.health()
        try AgentPayload.encode(health).write(
            to: root.appendingPathComponent(stage + ".json"), options: .atomic)
    }
}

private actor AttentionDeliveryAmbiguity {
    var delivered = false
    func first() -> Bool {
        guard !delivered else { return false }
        delivered = true
        return true
    }
}
