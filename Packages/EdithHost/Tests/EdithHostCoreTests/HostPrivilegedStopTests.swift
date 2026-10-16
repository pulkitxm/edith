import Darwin
import EdithExtensionSupport
import Foundation
import Testing

@testable import EdithHostCore

@Suite @MainActor struct HostPrivilegedStopTests {
    @Test func restorationWaitsForActualRegistryOwnerAfterCallerCompletion() async throws {
        let fixture = RestoreFixture()
        var owner: CheckedContinuation<Void, Never>?
        var callbackReturned = false
        var ownerReturned = false
        let token = UUID()
        fixture.commands.invoke(
            ["token": token.uuidString, "command": "synthetic.wait", "payload": Data()],
            completion: { _, _ in callbackReturned = true },
            execute: { _, _ in
                await withCheckedContinuation { owner = $0 }
                ownerReturned = true
                return Data()
            })
        while owner == nil { await Task.yield() }
        let worker = HostPrivilegedWorker(object: fixture)
        let stop = try stop(reason: .disable)
        var stopped = false
        let cleanup = Task {
            try await worker.prepareForStop(stop); stopped = true
        }
        while !callbackReturned { await Task.yield() }
        #expect(!ownerReturned)
        #expect(!stopped)
        #expect(fixture.restorations == 0)
        owner?.resume()
        try await cleanup.value
        #expect(ownerReturned)
        #expect(stopped)
        #expect(fixture.restorations == 1)
        #expect(fixture.suspensions == 1)
    }

    @Test func originalConfirmedQuitRelinquishesWithoutCallingSystemRestoration() async throws {
        let fixture = RestoreFixture()
        let worker = HostPrivilegedWorker(object: fixture)
        try await worker.prepareForStop(try stop(reason: .applicationQuit, retain: true))
        #expect(fixture.restorations == 0)
        try await worker.prepareForStop(try stop(reason: .disable))
        #expect(fixture.restorations == 1)
    }

    @Test(arguments: HostWorkerStopReason.allCases)
    func everyReasonWithoutConfirmedPolicyRestores(reason: HostWorkerStopReason) async throws {
        let fixture = RestoreFixture()
        try await HostPrivilegedWorker(object: fixture).prepareForStop(try stop(reason: reason))
        #expect(fixture.restorations == 1)
    }

    @Test func failedRestoreStillThrowsAndCanBeRetried() async throws {
        let fixture = RestoreFixture()
        fixture.reject = true
        let worker = HostPrivilegedWorker(object: fixture)
        await #expect(throws: NSError.self) {
            try await worker.prepareForStop(try stop(reason: .ownerLost))
        }
        fixture.reject = false
        try await worker.prepareForStop(try stop(reason: .ownerLost))
        #expect(fixture.restorations == 2)
    }

    @Test(arguments: ["owner", "reason", "worker", "parent", "host", "preference"])
    func forgedOrStaleQuitCannotBypassRestoration(field: String) async throws {
        let value = try stop(reason: .applicationQuit, retain: true)
        var object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        switch field {
        case "owner": object["owner"] = "other"
        case "reason": object["reason"] = "disable"
        case "worker", "parent":
            var identity = try #require(object[field] as? [String: Any])
            identity["generation"] = "0.0"
            object[field] = identity
        case "host", "preference":
            var policy = try #require(object["quitPolicy"] as? [String: Any])
            if field == "host" {
                var host = try #require(policy["host"] as? [String: Any])
                host["generation"] = "0.0"
                policy["host"] = host
            } else {
                policy["restoreOnQuit"] = true
            }
            object["quitPolicy"] = policy
        default: throw HostWorkerError.rejected
        }
        let forged = try JSONDecoder().decode(
            HostPrivilegedStop.self, from: JSONSerialization.data(withJSONObject: object))
        let fixture = RestoreFixture()
        let worker = HostPrivilegedWorker(object: fixture)
        await #expect(throws: HostWorkerError.rejected) { try await worker.prepareForStop(forged) }
        try await worker.prepareForStop(try stop(reason: .ownerLost))
        #expect(fixture.restorations == 1)
    }

    private func stop(reason: HostWorkerStopReason, retain: Bool = false) throws
        -> HostPrivilegedStop
    {
        let current = try #require(ExtensionProcessIdentity.current)
        return HostPrivilegedStop(
            reason: reason, owner: "lidAwake", worker: current,
            parent: try #require(ExtensionProcessIdentity.read(getppid())),
            quitPolicy: retain
                ? .init(reason: .applicationQuit, restoreOnQuit: false, host: current) : nil)
    }

    @MainActor private final class RestoreFixture: NSObject {
        let commands = ExtensionCommandRegistry()
        var suspensions = 0
        var restorations = 0
        var reject = false

        @objc(suspendCommandsWithCompletion:)
        func suspendCommands(completion: @escaping @convention(block) () -> Void) {
            suspensions += 1
            Task {
                await commands.suspendAndWait()
                completion()
            }
        }

        @objc(prepareDisableWithCompletion:)
        func prepareDisable(completion: @escaping @convention(block) (NSError?) -> Void) {
            restorations += 1
            completion(reject ? NSError(domain: "synthetic.restore", code: 1) : nil)
        }
    }
}
