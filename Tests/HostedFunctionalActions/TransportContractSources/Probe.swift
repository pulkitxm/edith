import Foundation
@MainActor final class InertCase: HostedFunctionalActionCase {
    static let owner = "keepAwake"
    static let activationOperation = "keepAwake.ui.update"
    func activateOriginalControl(context: HostedFunctionalActionContext) async throws {}
    func readAuthoritativeState(context: HostedFunctionalActionContext) async throws -> Data {
        Data("{}".utf8)
    }
    func readPersistentState(context: HostedFunctionalActionContext) async throws -> Data? { nil }
    func shutdownPresentation() async {}
}
@main struct SyntheticProbe {
    @MainActor static func main() async throws {
        let session = "12345678-1234-4123-8123-123456789abc"
        let root = "/private/synthetic/functional-fixture-" + session
        let hash = String(repeating: "b", count: 64)
        func peer(_ pid: Int) -> [String: Any] {
            [
                "pid": pid, "birthSeconds": 1000, "birthMicroseconds": pid, "uid": 501,
                "executableSHA256": hash,
            ]
        }
        let object: [String: Any] = [
            "schema": 1, "sourceCommit": String(repeating: "a", count: 40), "session": session,
            "owner": "keepAwake", "uid": 501,
            "fixtureRoot": root, "hostIdentifier": "com.pulkit.edith.tests.worker-" + session,
            "home": root + "/keepAwake-home",
            "dataDirectory": root + "/data/keepAwake", "hostABI": "edith-host-2",
            "caseSHA256": hash,
            "activationOperation": "keepAwake.ui.update", "phase": "initial",
            "pairScope": "synthetic-development",
            "previousVersion": "1.0.0", "currentVersion": "1.1.0", "version": "1.0.0",
            "packageSHA256": hash,
            "engine": peer(10), "ui": peer(11),
            "operations": ["keepAwake.ui.update", "system.arbitrary"],
            "ownedPaths": [
                [
                    "name": "commands", "path": root + "/ExtensionState/Commands",
                    "kind": "directory",
                ]
            ],
        ]
        let bytes = try JSONSerialization.data(
            withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        let context = try HostedFunctionalActionContext.decode(bytes)
        try context.validate(
            source: String(repeating: "a", count: 40), owner: "keepAwake", session: session,
            uid: 501, root: root,
            caseSHA256: hash,
            engine: .init(
                pid: 10, birthSeconds: 1000, birthMicroseconds: 10, uid: 501, executableSHA256: hash
            ),
            ui: .init(
                pid: 11, birthSeconds: 1000, birthMicroseconds: 11, uid: 501, executableSHA256: hash
            ))

        func transport(
            verify: @escaping @MainActor () async throws -> Void = {},
            observe:
                @escaping @MainActor (HostedFunctionalActionTransport.Invocation) async throws ->
                Void = { _ in }
        ) throws -> HostedFunctionalActionTransport {
            try HostedFunctionalActionTransport(
                context: context, presentationID: UUID(), verifyCurrent: verify, observe: observe,
                validatePayload: { _, bytes in
                    guard try HostedFunctionalJSON.object(bytes).isEmpty else {
                        throw HostedFunctionalActionError.invalid
                    }
                }, observeBeforeSend: { _ in }, observePersistentBefore: { _ in })
        }
        for authoritative in [false, true] {
            SyntheticEndpoint.starts = 0
            let value = try transport()
            let invocation = Task { @MainActor in
                if authoritative { return try await value.readAuthoritative("keepAwake.ui.update") }
                return try await value.invokeOriginal(
                    "keepAwake.ui.update", payload: Data("{}".utf8))
            }
            while SyntheticEndpoint.continuation == nil { await Task.yield() }
            var drained = false
            let stop = Task { @MainActor in
                await value.shutdown(); drained = true
            }
            for _ in 0..<20 { await Task.yield() }
            precondition(!drained)
            SyntheticEndpoint.continuation?.resume(returning: Data("{}".utf8));
            SyntheticEndpoint.continuation = nil
            await stop.value
            guard case .failure = await invocation.result else { fatalError("late success") }
            precondition(value.originalInvocationCount == 0)
        }
        print("PASS direct original and authoritative routes are cancelled and awaited")
        var verifier: CheckedContinuation<Void, Never>?
        SyntheticEndpoint.starts = 0
        let second = try transport(verify: { await withCheckedContinuation { verifier = $0 } })
        let racing = Task { @MainActor in
            try await second.invokeOriginal("keepAwake.ui.update", payload: Data("{}".utf8))
        }
        while verifier == nil { await Task.yield() }
        let stopSecond = Task { @MainActor in await second.shutdown() }
        for _ in 0..<20 { await Task.yield() }
        verifier?.resume(); verifier = nil
        await stopSecond.value
        guard case .failure = await racing.result else { fatalError("post-stop send") }
        precondition(SyntheticEndpoint.starts == 0)
        print("PASS no endpoint send after stop during verification")
        var waiting: [CheckedContinuation<Void, Never>] = []
        let bounded = try transport(verify: { await withCheckedContinuation { waiting.append($0) } }
        )
        var pending: [Task<Data, Error>] = []
        for count in 1...8 {
            pending.append(
                Task { @MainActor in
                    try await bounded.invokeOriginal(
                        "keepAwake.ui.update", payload: Data("{}".utf8))
                })
            while waiting.count < count { await Task.yield() }
        }
        do {
            _ = try await bounded.invokeOriginal("keepAwake.ui.update", payload: Data("{}".utf8));
            fatalError("direct route exceeded bound")
        } catch {}
        let stopBounded = Task { @MainActor in await bounded.shutdown() }
        for _ in 0..<20 { await Task.yield() }
        waiting.forEach { $0.resume() }; waiting.removeAll()
        await stopBounded.value
        for task in pending {
            guard case .failure = await task.result else {
                fatalError("bounded route late success")
            }
        }
        precondition(SyntheticEndpoint.starts == 0)
        print("PASS direct original routes share the eight-call concurrency bound")
        var observer: CheckedContinuation<Void, Never>?
        let third = try transport(observe: { _ in await withCheckedContinuation { observer = $0 } })
        let observing = Task { @MainActor in
            try await third.invokeOriginal("keepAwake.ui.update", payload: Data("{}".utf8))
        }
        while SyntheticEndpoint.continuation == nil { await Task.yield() }
        SyntheticEndpoint.continuation?.resume(returning: Data("{}".utf8));
        SyntheticEndpoint.continuation = nil
        while observer == nil { await Task.yield() }
        let stopThird = Task { @MainActor in await third.shutdown() }
        for _ in 0..<20 { await Task.yield() }
        observer?.resume(); observer = nil
        await stopThird.value
        guard case .failure = await observing.result else { fatalError("post-stop ACK") }
        precondition(third.originalInvocationCount == 0)
        print("PASS no acknowledgement after stop during observation")
        let fourth = try transport()
        let prior = Task { @MainActor in
            try await fourth.invokeOriginal("keepAwake.ui.update", payload: Data("{}".utf8))
        }
        while SyntheticEndpoint.continuation == nil { await Task.yield() }
        SyntheticEndpoint.continuation?.resume(returning: Data("{}".utf8));
        SyntheticEndpoint.continuation = nil
        _ = try await prior.value
        do {
            _ = try await HostedFunctionalActionNativeDriver.run(
                context: context, transport: fourth, makeCase: { InertCase() });
            fatalError("historical ACK admitted")
        } catch {}
        print("PASS historical ACK cannot qualify inert current activation")
        let fifth = try transport()
        let request = ExtensionEngineRequest(
            presentationID: fifth.presentationID, operation: "keepAwake.ui.update")
        let encoded = try ExtensionEngineWire.encode(request)
        let startCount = SyntheticEndpoint.starts
        for prefix in [
            "\"unreviewed\":true,", "\"presentationID\":\"foreign\",",
            "\"\\u0070resentationID\":\"foreign\",",
        ] {
            let input = Data(
                ("{" + prefix + String(decoding: encoded, as: UTF8.self).dropFirst()).utf8)
            let completed = await withCheckedContinuation { continuation in
                fifth.invoke(
                    input as NSData, completion: { continuation.resume(returning: $0 as Data) })
            }
            precondition(completed == Data("{}".utf8))
        }
        precondition(SyntheticEndpoint.starts == startCount)
        await fifth.shutdown()
        print("PASS unknown and duplicate bridge fields rejected before endpoint")
    }
}
