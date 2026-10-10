import Foundation
import Security
import Testing
@testable import JevExtension

private final class JevResponseGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var released = false

    func wait() {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(3)
        while !released {
            guard condition.wait(until: deadline) else { return }
        }
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}

@Suite struct JevOwnershipTests {
    @Test func syntheticKeysPersistAcrossWorkerInstancesWithoutKeychainAccess() throws {
        let identifier = "com.pulkit.edith.tests.jev-" + UUID().uuidString
        let suite = identifier + ".extensions.jev"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let environment = [
            "EDITH_APPLICATION_IDENTIFIER": identifier,
            "EDITH_SHARED_DEFAULTS_SUITE": suite,
            "EDITH_EXTENSION_FIXTURE_HOME": NSTemporaryDirectory(),
        ]
        let first = JevKeyStores.make(environment: environment)
        #expect(first is FixtureJevKeyStore)
        #expect(first.read() == .missing)
        #expect(first.write("synthetic-key"))
        let replacement = JevKeyStores.make(environment: environment)
        #expect(replacement.read() == .key("synthetic-key"))
        #expect(replacement.write(nil))
        #expect(first.read() == .missing)
    }

    @Test func productionAndMismatchedSuitesAlwaysUseKeychain() {
        for environment in [
            [String: String](),
            [
                "EDITH_APPLICATION_IDENTIFIER": "com.pulkit.edith",
                "EDITH_SHARED_DEFAULTS_SUITE": "com.pulkit.edith.extensions.jev",
                "EDITH_EXTENSION_FIXTURE_HOME": NSTemporaryDirectory(),
            ],
            [
                "EDITH_APPLICATION_IDENTIFIER": "com.pulkit.edith.tests.synthetic",
                "EDITH_SHARED_DEFAULTS_SUITE": "com.pulkit.edith.extensions.jev",
                "EDITH_EXTENSION_FIXTURE_HOME": NSTemporaryDirectory(),
            ],
        ] {
            #expect(JevKeyStores.make(environment: environment) is KeychainJevKeyStore)
        }
    }

    @Test func keyStoresAreIsolatedWithoutAccessingRealKeychainItems() {
        let first = KeychainJevKeyStore(service: "fixture.first.extensions.jev")
        let second = KeychainJevKeyStore(service: "fixture.second.extensions.jev")
        #expect(
            first.baseQuery()[kSecAttrService as String] as? String != second.baseQuery()[
                kSecAttrService as String] as? String)
        #expect(first.baseQuery()[kSecAttrAccount as String] as? String == "typesafe-api-key")
    }

    @Test func replacingKeyRejectsOldInFlightDecisionsAndTheirCache() async throws {
        let gate = JevResponseGate()
        defer { gate.release() }
        let (_, host) = JevStubProtocol.register { request, _ in
            if request.value(forHTTPHeaderField: "Authorization") == "Bearer first-key" {
                gate.wait()
            }
            return (200, jevNoulResponse)
        }
        let engine = JevEngine(
            store: MemoryJevKeyStore("first-key"),
            makeClient: { key in
                JevStubProtocol.client(host: host, key: key)
            })
        let request = JevRequest(state: .text("synthetic"), questions: ["ok": .noul("ok?")])
        let pending = Task { try await engine.decide(request, purpose: "fixture") }
        let deadline = ContinuousClock.now + .seconds(2)
        while JevStubProtocol.requests(for: host).isEmpty {
            try #require(ContinuousClock.now < deadline)
            try await Task.sleep(for: .milliseconds(5))
        }
        await engine.setKey("second-key")
        gate.release()
        await #expect(throws: CancellationError.self) { try await pending.value }
        _ = try await engine.decide(request, purpose: "fixture")
        #expect(JevStubProtocol.requests(for: host).count == 2)
        #expect(
            JevStubProtocol.requests(for: host).last?.0.value(forHTTPHeaderField: "Authorization")
                == "Bearer second-key")
    }

    @MainActor @Test func disabledCommandsCannotReadOrChangeSavedKey() {
        let store = MemoryJevKeyStore()
        let commands = JevCommands(engine: JevEngine(store: store))
        commands.shutdown()
        var completions = 0
        commands.invoke(
            ["token": UUID().uuidString, "command": "jev.status", "payload": Data()] as NSDictionary
        ) { data, message in
            completions += 1
            #expect(data == nil)
            #expect(message != nil)
        }
        #expect(completions == 1)
        #expect(store.reads == 0)
        #expect(store.stored == nil)
    }
}
