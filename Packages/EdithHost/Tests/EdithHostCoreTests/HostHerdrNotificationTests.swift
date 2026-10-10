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
            ]))
    }

    private func descriptor() throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "version": 1, "owner": "herdr", "location": "herdr.agent",
            "target": "synthetic-host.synthetic-agent.diff",
            "token": UUID().uuidString, "title": "Synthetic agent", "width": 900, "height": 600,
            "minimumWidth": 400, "minimumHeight": 300, "presented": false,
        ])
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

    @Test func exactCurrentDescriptorAndRealOpenAreRequiredForSuccess() async throws {
        let config = try configuration()
        let descriptor = try descriptor()
        let target = try HostHerdrWindowTarget.decode(descriptor)
        let inventory = try JSONSerialization.data(withJSONObject: [
            "presentations": [
                try JSONSerialization.jsonObject(with: descriptor)
            ]
        ])
        var operations: [String] = []
        var opened: HostWorkerNavigationRequest?
        let presentation = UUID()
        let router = HostHerdrNotificationRouter(currentVersion: { "1" }) { version in
            #expect(version == "1")
            return HostHerdrNotificationLease(
                configuration: config, presentationID: presentation, enginePID: 42,
                engineGeneration: "synthetic",
                validateOrigin: {},
                invoke: { operation, payload in
                    operations.append(operation)
                    if operation == "herdr.ui.notification.open" {
                        let object = try #require(
                            JSONSerialization.jsonObject(with: payload) as? [String: String])
                        #expect(Set(object.keys) == ["agentID", "hostID", "view"])
                        return descriptor
                    }
                    #expect(operation == "herdr.ui.read")
                    return inventory
                }, open: { opened = $0 })
        }
        try await router.receive(HostHerdrNotificationRequest(userInfo: userInfo))
        #expect(operations == ["herdr.ui.notification.open", "herdr.ui.read"])
        #expect(opened?.presentationID == presentation)
        #expect(opened?.herdrWindow == target)
        #expect(router.pendingCount == 0)
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

    @Test func staleReadyOwnerOrMissingDescriptorFailsBeforeOpen() async throws {
        for failure in ["prepare", "engine", "descriptor", "open"] {
            let config = try configuration()
            let descriptor = try descriptor()
            var current: String? = "1"
            var admitted = true
            var opens = 0
            let router = HostHerdrNotificationRouter(currentVersion: { current }) { _ in
                if failure == "prepare" { current = "2" }
                return HostHerdrNotificationLease(
                    configuration: config, presentationID: UUID(), enginePID: 42,
                    engineGeneration: "synthetic",
                    validateOrigin: { guard admitted else { throw HostWorkerError.rejected } },
                    invoke: { operation, _ in
                        if operation == "herdr.ui.notification.open" {
                            if failure == "engine" { admitted = false }
                            return descriptor
                        }
                        if failure == "descriptor" { return Data("{\"presentations\":[]}".utf8) }
                        return try JSONSerialization.data(withJSONObject: [
                            "presentations": [
                                try JSONSerialization.jsonObject(with: descriptor)
                            ]
                        ])
                    },
                    open: { _ in
                        opens += 1; throw HostWorkerError.rejected
                    })
            }
            await #expect(throws: HostWorkerError.rejected) {
                try await router.receive(HostHerdrNotificationRequest(userInfo: userInfo))
            }
            #expect(opens == (failure == "open" ? 1 : 0))
            #expect(router.pendingCount == 0)
        }
    }

    @Test func hiddenPresentationCancelsPendingEngineCall() async throws {
        let config = try configuration()
        var admitted = true
        var began = false
        var opens = 0
        let router = HostHerdrNotificationRouter(currentVersion: { "1" }) { _ in
            HostHerdrNotificationLease(
                configuration: config, presentationID: UUID(), enginePID: 42,
                engineGeneration: "synthetic",
                validateOrigin: { guard admitted else { throw HostWorkerError.rejected } },
                invoke: { _, _ in
                    began = true
                    try await Task.sleep(for: .seconds(10))
                    throw HostWorkerError.rejected
                }, open: { _ in opens += 1 })
        }
        let request = try HostHerdrNotificationRequest(userInfo: userInfo)
        let task = Task { try await router.receive(request) }
        while !began { await Task.yield() }
        admitted = false
        await #expect(throws: CancellationError.self) { try await task.value }
        await router.drain()
        #expect(opens == 0)
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
