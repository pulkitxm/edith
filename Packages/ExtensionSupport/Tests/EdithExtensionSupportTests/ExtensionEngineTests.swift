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

    @Test func failedRepliesCarryTheirMessageAndLongRequestsAreAdmitted() async throws {
        let bridge = Bridge()
        bridge.mode = "explain"
        let client = try #require(ExtensionEngineClient(bridge: bridge, presentationID: UUID()))
        do {
            _ = try await client.invoke("sample.read")
            Issue.record("the request should have failed")
        } catch {
            #expect(error as? ExtensionEngineError == .failed("git is not installed"))
            #expect(error.localizedDescription == "git is not installed")
        }
        bridge.mode = "echo"
        #expect(try await client.invoke("sample.authors", timeout: 600) == Data("{}".utf8))
        await #expect(throws: ExtensionEngineError.rejected) {
            try await client.invoke("sample.authors", timeout: 601)
        }
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
        let limit = ExtensionEngineWire.maximumConcurrentRequests
        let tasks = (0..<limit).map { _ in Task { try await client.invoke("sample.hold") } }
        try await wait { bridge.callbacks.count == limit }
        await #expect(throws: ExtensionEngineError.unavailable) {
            try await client.invoke("sample.hold")
        }
        client.invalidate()
        for task in tasks {
            await #expect(throws: ExtensionEngineError.unavailable) { try await task.value }
        }
        #expect(bridge.callbacks.isEmpty)
        #expect(bridge.cancelled.count == 2 + limit)
        await #expect(throws: ExtensionEngineError.unavailable) {
            try await client.invoke("sample.read")
        }
    }

    @Test(arguments: [1, 8, 12]) func snapshotReadsAreNotRejectedOrDelayedBySlowRequests(
        slowCount: Int
    ) async throws {
        let bridge = Bridge()
        bridge.mode = "holdSlow"
        let client = try #require(ExtensionEngineClient(bridge: bridge, presentationID: UUID()))
        defer { client.invalidate() }
        let slow = (0..<slowCount).map { _ in Task { try await client.invoke("sample.slow") } }
        try await wait { bridge.callbacks.count == slowCount }
        var timings: [Double] = []
        for _ in 0..<15 {
            let start = ContinuousClock.now
            #expect(try await client.invoke("sample.snapshot") == Data("{}".utf8))
            let elapsed = ContinuousClock.now - start
            timings.append(
                Double(elapsed.components.seconds) * 1_000
                    + Double(elapsed.components.attoseconds) / 1e15)
        }
        print("LATENCY engine client slow=\(slowCount) median ms", timings.sorted()[7])
        #expect(timings.sorted()[7] < 50)
        let burst = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<12 {
                group.addTask { @MainActor in
                    (try? await client.invoke("sample.snapshot")) != nil
                }
            }
            return await group.reduce(0) { $0 + ($1 ? 1 : 0) }
        }
        #expect(burst == 12)
        client.invalidate()
        for task in slow { _ = try? await task.value }
    }

    @Test func invalidationAndCancellationClaimEachHeldRequestOnlyOnce() async throws {
        let bridge = Bridge()
        bridge.mode = "hold"
        let client = try #require(ExtensionEngineClient(bridge: bridge, presentationID: UUID()))
        defer { client.invalidate() }
        let task = Task { try await client.invoke("sample.hold") }
        try await wait { bridge.callbacks.count == 1 }
        let token = try #require(bridge.callbacks.keys.first)
        client.invalidate()
        task.cancel()
        await #expect(throws: ExtensionEngineError.unavailable) { try await task.value }
        for _ in 0..<8 { await Task.yield() }
        #expect(bridge.cancellationCalls == [token])
        #expect(bridge.callbacks.isEmpty)
    }

    @Test func anAlreadyCancelledRequestSendsOnlyOneBridgeCancellation() async throws {
        let bridge = Bridge()
        bridge.mode = "hold"
        let client = try #require(ExtensionEngineClient(bridge: bridge, presentationID: UUID()))
        defer { client.invalidate() }
        let task = Task { try await client.invoke("sample.hold") }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        for _ in 0..<8 { await Task.yield() }
        #expect(bridge.cancellationCalls.count == 1)
        #expect(bridge.callbacks.isEmpty)
        client.invalidate()
        #expect(bridge.cancellationCalls.count == 1)
    }

    @Test(arguments: [false, true])
    func completionAndCancellationHaveOneWinner(completionFirst: Bool) async throws {
        let bridge = Bridge()
        bridge.mode = "hold"
        let client = try #require(ExtensionEngineClient(bridge: bridge, presentationID: UUID()))
        defer { client.invalidate() }
        let task = Task { try await client.invoke("sample.hold") }
        try await wait { bridge.callbacks.count == 1 }
        let token = try #require(bridge.callbacks.keys.first)
        let removed = bridge.callbacks.removeValue(forKey: token)
        let completion = try #require(removed)
        let payload = Data("{\"value\":\"synthetic\"}".utf8)
        let reply = try ExtensionEngineWire.encode(
            ExtensionEngineReply(token: token, ok: true, payload: payload))
        if completionFirst {
            completion(reply)
            task.cancel()
        } else {
            task.cancel()
            completion(reply)
        }
        var completed = false
        do {
            #expect(try await task.value == payload)
            completed = true
        } catch is CancellationError {
        } catch {
            Issue.record(error)
        }
        for _ in 0..<8 { await Task.yield() }
        #expect(bridge.cancellationCalls == (completed ? [] : [token]))
        client.invalidate()
        #expect(bridge.cancellationCalls == (completed ? [] : [token]))
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
        var cancellationCalls: [UUID] = []

        @objc func invoke(_ data: Data, completion: @escaping (Data) -> Void) {
            guard
                let request = try? ExtensionEngineWire.decode(
                    ExtensionEngineRequest.self, from: data)
            else { completion(Data()); return }
            lastPresentation = request.presentationID
            if mode == "hold" || (mode == "holdSlow" && request.operation == "sample.slow") {
                callbacks[request.token] = completion; return
            }
            let reply = ExtensionEngineReply(
                token: mode == "mismatch" ? UUID() : request.token,
                ok: mode != "reject" && mode != "explain",
                payload: mode == "nonJSON" ? Data("malformed".utf8) : request.payload,
                message: mode == "explain" ? "git is not installed" : nil)
            completion((try? ExtensionEngineWire.encode(reply)) ?? Data())
        }

        @objc func cancel(_ token: String) {
            guard let token = UUID(uuidString: token) else { return }
            cancelled.insert(token)
            cancellationCalls.append(token)
            callbacks[token] = nil
        }
    }
}
