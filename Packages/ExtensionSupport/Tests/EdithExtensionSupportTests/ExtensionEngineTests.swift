import Foundation
import Testing
@testable import EdithExtensionSupport

@MainActor
struct ExtensionEngineTests {
    @Test func clientUsesTheFoundationBridgeAndValidatesResponseOwnershipAndJSON() async throws {
        let bridge = Bridge()
        let presentation = UUID()
        let client = try #require(
            ExtensionEngineClient(bridge: bridge, presentationID: presentation))
        let payload = Data("{\"title\":\"Synthetic UTF8 café\"}".utf8)
        #expect(try await client.invoke("sample.read", payload: payload) == payload)
        #expect(bridge.lastPresentation == presentation)
        for mode in ["mismatch", "nonJSON", "reject"] {
            bridge.mode = mode
            await #expect(throws: (any Error).self) { try await client.invoke("sample.read") }
        }
        bridge.mode = "echo"
        #expect(try await client.invoke("sample.read") == Data("{}".utf8))
        for operation in [
            "extension.native.authorize", "../../execute", "", String(repeating: "x", count: 129),
        ] {
            await #expect(throws: ExtensionEngineError.rejected) {
                try await client.invoke(operation)
            }
        }
        await #expect(throws: ExtensionEngineError.rejected) {
            try await client.invoke("sample.read", payload: Data("malformed".utf8))
        }
        #expect(ExtensionEngineClient(bridge: NSObject(), presentationID: presentation) == nil)
    }

    @Test func clientCancellationTimeoutAndInvalidationCancelOnlyTheirOwnedRequests() async throws {
        let bridge = Bridge()
        bridge.mode = "hold"
        let client = try #require(ExtensionEngineClient(bridge: bridge, presentationID: UUID()))
        await #expect(throws: ExtensionEngineError.timedOut) {
            try await client.invoke("sample.hold", timeout: 0.02)
        }
        #expect(bridge.cancelled.count == 1)
        let cancelled = Task { try await client.invoke("sample.hold") }
        try await wait { bridge.callbacks.count == 1 }
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(bridge.cancelled.count == 2)
        let tasks = (0..<8).map { _ in Task { try await client.invoke("sample.hold") } }
        try await wait { bridge.callbacks.count == 8 }
        await #expect(throws: ExtensionEngineError.unavailable) {
            try await client.invoke("sample.hold")
        }
        client.invalidate()
        for task in tasks {
            await #expect(throws: ExtensionEngineError.unavailable) { try await task.value }
        }
        #expect(bridge.callbacks.isEmpty)
        #expect(bridge.cancelled.count == 10)
        await #expect(throws: ExtensionEngineError.unavailable) {
            try await client.invoke("sample.read")
        }
    }

    @Test func sealedUIAdmissionRequiresItsOwnIdentityAndKeepsDisabledSettingsEngineFree() throws {
        let bridge = Bridge()
        let suite = "synthetic.host.extension.sample.worker"
        let context: NSDictionary = [
            "remoteUI": true, "hostIdentifier": "synthetic.host", "extensionID": "sample",
            "defaultsSuite": suite, "presentationID": UUID().uuidString, "uiOnly": false,
            "location": "main", "engineClient": bridge,
        ]
        #expect(
            ExtensionUIConfiguration(
                context: context, hostIdentifier: "synthetic.host", extensionID: "sample",
                defaultsSuite: suite)?.engineClient != nil)
        #expect(
            ExtensionUIConfiguration(
                context: context, hostIdentifier: "other.host", extensionID: "sample",
                defaultsSuite: suite) == nil)
        let settings = NSMutableDictionary(dictionary: context)
        settings["uiOnly"] = true
        settings["location"] = "settings"
        #expect(
            ExtensionUIConfiguration(
                context: settings, hostIdentifier: "synthetic.host", extensionID: "sample",
                defaultsSuite: suite) == nil)
        settings.removeObject(forKey: "engineClient")
        let admitted = try #require(
            ExtensionUIConfiguration(
                context: settings, hostIdentifier: "synthetic.host", extensionID: "sample",
                defaultsSuite: suite))
        #expect(admitted.uiOnly)
        #expect(admitted.engineClient == nil)
        settings["location"] = "home"
        #expect(
            ExtensionUIConfiguration(
                context: settings, hostIdentifier: "synthetic.host", extensionID: "sample",
                defaultsSuite: suite) == nil)
    }

    private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw ExtensionEngineError.timedOut }
            await Task.yield()
        }
    }

    @MainActor private final class Bridge: NSObject {
        var mode = "echo"
        var lastPresentation: UUID?
        var callbacks: [UUID: (Data) -> Void] = [:]
        var cancelled = Set<UUID>()

        @objc func invoke(_ data: Data, completion: @escaping (Data) -> Void) {
            guard
                let request = try? ExtensionEngineWire.decode(
                    ExtensionEngineRequest.self, from: data)
            else { completion(Data()); return }
            lastPresentation = request.presentationID
            if mode == "hold" { callbacks[request.token] = completion; return }
            let reply = ExtensionEngineReply(
                token: mode == "mismatch" ? UUID() : request.token, ok: mode != "reject",
                payload: mode == "nonJSON" ? Data("malformed".utf8) : request.payload)
            completion((try? ExtensionEngineWire.encode(reply)) ?? Data())
        }

        @objc func cancel(_ token: String) {
            guard let token = UUID(uuidString: token) else { return }
            cancelled.insert(token)
            callbacks[token] = nil
        }
    }
}
