import Foundation
import Testing

@testable import EdithHostCore

@Suite @MainActor struct HostHerdrNotificationTests {
    private var userInfo: [AnyHashable: Any] {
        [
            "identifier": "synthetic-notification", "title": "Synthetic agent",
            "body": "Synthetic event",
            "agentID": "synthetic-agent", "hostID": "synthetic-host", "view": "diff",
        ]
    }

    private func configuration() throws -> HostWorkerConfiguration {
        try JSONDecoder().decode(
            HostWorkerConfiguration.self,
            from: JSONSerialization.data(withJSONObject: [
                "identifier": "com.example.synthetic.notification",
                "supportDirectory": "file:///tmp/synthetic-notification",
                "extensionID": "herdr", "version": "1", "theme": "accent", "appearance": "system",
                "zoom": 1, "recoveryOnly": false,
                "ambientPolicy": [
                    "pauseAmbientOnBattery": false, "subscribers": ["sessions.discover": 0],
                ],
            ]))
    }

    @Test func originalScalarOpenRequestIsClosed() throws {
        let request = try HostHerdrNotificationRequest(userInfo: userInfo)
        #expect(request.agentID == "synthetic-agent")
        #expect(request.hostID == "synthetic-host")
        #expect(request.view == .diff)
        for view in ["agent", "diff", "split"] {
            var value = userInfo; value["view"] = view
            _ = try HostHerdrNotificationRequest(userInfo: value)
        }
        for pair: (String, Any) in [
            ("view", "arbitrary"), ("agentID", 1), ("hostID", ""),
            ("agentID", String(repeating: "x", count: 4097)), ("body", "bad\0body"),
            ("method", "filesystem.open"), ("path", "/tmp/mock"),
        ] {
            var value = userInfo; value[pair.0] = pair.1
            #expect(throws: HostWorkerError.rejected) {
                try HostHerdrNotificationRequest(userInfo: value)
            }
        }
        var missing = userInfo; missing.removeValue(forKey: "identifier")
        #expect(throws: HostWorkerError.rejected) {
            try HostHerdrNotificationRequest(userInfo: missing)
        }
    }

    @Test func exactMainAcknowledgmentPreservesOriginalAgentAndDiffSelection() async throws {
        let config = try configuration()
        var operations: [String] = []
        var validations = 0
        let router = HostHerdrNotificationRouter(currentVersion: { "1" }) { version in
            #expect(version == "1")
            return HostHerdrNotificationLease(
                configuration: config, presentationID: UUID(), enginePID: 42,
                engineGeneration: "synthetic", validateOrigin: { validations += 1 },
                invoke: { operation, payload in
                    operations.append(operation)
                    let object = try #require(
                        JSONSerialization.jsonObject(with: payload) as? [String: String])
                    #expect(Set(object.keys) == ["agentID", "hostID", "view"])
                    #expect(object["view"] == "diff")
                    #expect(object["agentID"] == "synthetic-agent")
                    #expect(object["hostID"] == "synthetic-host")
                    return Data("{\"ok\":true}".utf8)
                })
        }
        try await router.receive(HostHerdrNotificationRequest(userInfo: userInfo))
        #expect(operations == ["herdr.ui.notification.open"])
        #expect(validations >= 3 && router.pendingCount == 0)
    }

    @Test func disabledHerdrNeverPreparesOrEnables() async throws {
        var prepares = 0
        let router = HostHerdrNotificationRouter(currentVersion: { nil }) { _ in
            prepares += 1; throw HostWorkerError.rejected
        }
        await #expect(throws: HostWorkerError.rejected) {
            try await router.receive(HostHerdrNotificationRequest(userInfo: userInfo))
        }
        #expect(prepares == 0)
    }

    @Test func staleMainLeaseOrMalformedAcknowledgmentCannotSucceed() async throws {
        for reply in [
            Data(), Data("{\"ok\":false}".utf8), Data("{\"ok\":1}".utf8),
            Data("{\"ok\":true,\"location\":\"herdr.agent\"}".utf8),
            Data(repeating: 32, count: 1025), Data("{\"presentations\":[]}".utf8),
        ] {
            let lease = HostHerdrNotificationLease(
                configuration: try configuration(), presentationID: UUID(), enginePID: 42,
                engineGeneration: "synthetic", validateOrigin: {}, invoke: { _, _ in reply })
            await #expect(throws: (any Error).self) {
                try await lease.apply(
                    HostHerdrNotificationRequest(userInfo: userInfo), version: "1")
            }
        }
        for failure in ["prepare", "engine", "renderer", "version"] {
            let config = try configuration()
            var current: String? = "1"
            var admitted = true
            var invokes = 0
            let router = HostHerdrNotificationRouter(currentVersion: { current }) { _ in
                if failure == "prepare" { current = "2" }
                return HostHerdrNotificationLease(
                    configuration: config, presentationID: UUID(), enginePID: 42,
                    engineGeneration: "synthetic",
                    validateOrigin: { guard admitted else { throw HostWorkerError.rejected } },
                    invoke: { _, _ in
                        invokes += 1
                        if failure == "engine" || failure == "renderer" { admitted = false }
                        if failure == "version" { current = "2" }
                        return Data("{\"ok\":true}".utf8)
                    })
            }
            await #expect(throws: HostWorkerError.rejected) {
                try await router.receive(HostHerdrNotificationRequest(userInfo: userInfo))
            }
            #expect(invokes == (failure == "prepare" ? 0 : 1))
            #expect(router.pendingCount == 0)
        }
    }

    @Test func hiddenPresentationCancelsPendingEngineCall() async throws {
        let config = try configuration()
        var admitted = true
        var began = false
        let router = HostHerdrNotificationRouter(currentVersion: { "1" }) { _ in
            HostHerdrNotificationLease(
                configuration: config, presentationID: UUID(), enginePID: 42,
                engineGeneration: "synthetic",
                validateOrigin: { guard admitted else { throw HostWorkerError.rejected } },
                invoke: { _, _ in
                    began = true
                    try await Task.sleep(for: .seconds(10))
                    throw HostWorkerError.rejected
                })
        }
        let request = try HostHerdrNotificationRequest(userInfo: userInfo)
        let task = Task { try await router.receive(request) }
        while !began { await Task.yield() }
        admitted = false
        await #expect(throws: CancellationError.self) { try await task.value }
        await router.drain()
        #expect(router.pendingCount == 0)
    }

    @Test func stopCancelsOutstandingEnginePreparation() async throws {
        var preparing = false
        let router = HostHerdrNotificationRouter(currentVersion: { "1" }) { _ in
            preparing = true
            try await Task.sleep(for: .seconds(10))
            throw HostWorkerError.rejected
        }
        let request = try HostHerdrNotificationRequest(userInfo: userInfo)
        let task = Task { try await router.receive(request) }
        while !preparing { await Task.yield() }
        router.stop()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(router.pendingCount == 0)
    }
}
