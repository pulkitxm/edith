import Foundation
import Testing

@testable import MachinesExtension

@Suite(.serialized) @MainActor struct MachineHostWindowNavigationTests {
    @Test func originalKindsUseOnlyOwnDTOAndAwaitHostAcknowledgement() async throws {
        let bridge = MachineNavigationFixture()
        let client = try #require(MachineHostWindowNavigationClient(bridge: bridge))
        for kind in [MachineHostWindowRequest.Kind.machine, .files, .docker, .terminal] {
            let request = request(kind: kind)
            var completed = false
            let task = Task {
                try await client.open(request); completed = true
            }
            try await wait { bridge.pending.count == 1 }
            #expect(!completed)
            let value = try #require(bridge.requests.last)
            #expect(value["kind"] as? String == kind.rawValue)
            #expect(value["machineID"] as? String == request.machineID.uuidString)
            #expect(value["presentationID"] as? String == request.presentationID?.uuidString)
            #expect(
                Set(value.allKeys.compactMap { $0 as? String })
                    == (kind == .files
                        ? ["kind", "machineID", "presentationID", "path"]
                        : ["kind", "machineID", "presentationID"]))
            #expect(value["path"] as? String == request.path)
            bridge.complete(try #require(bridge.pending.keys.first))
            try await task.value
            #expect(completed)
        }
        #expect(bridge.cancelled.isEmpty)
        client.invalidate()
    }

    @Test func hostFailureRemainsAnErrorAndNeverAcknowledgesSuccess() async throws {
        let bridge = MachineNavigationFixture()
        let client = try #require(MachineHostWindowNavigationClient(bridge: bridge))
        let task = Task { try await client.open(request()) }
        try await wait { bridge.pending.count == 1 }
        bridge.complete(
            try #require(bridge.pending.keys.first), error: "Synthetic admission rejection")
        do { try await task.value; Issue.record("Rejected host acknowledged success") } catch let
            error as MachineUIFailure
        { #expect(error.message == "Synthetic admission rejection") }
        #expect(bridge.cancelled.count == 1)
        client.invalidate()
    }

    @Test func cancellationUsesExactOwnedTokenAndLateReplyCannotReviveRequest() async throws {
        let bridge = MachineNavigationFixture()
        let client = try #require(MachineHostWindowNavigationClient(bridge: bridge))
        let task = Task { try await client.open(request()) }
        try await wait { bridge.pending.count == 1 }
        let token = try #require(bridge.pending.keys.first)
        let late = try #require(bridge.pending[token])
        task.cancel()
        do { try await task.value; Issue.record("Cancelled request succeeded") } catch {
            #expect(error is CancellationError)
        }
        #expect(bridge.cancelled == [token])
        late(nil)
        await Task.yield()
        #expect(bridge.pending.isEmpty)
        client.invalidate()
    }

    @Test func deadlineAndDisableCancelAndDrainEveryOwnedRequest() async throws {
        let bridge = MachineNavigationFixture()
        let client = try #require(
            MachineHostWindowNavigationClient(
                bridge: bridge, timeout: .milliseconds(20)))
        do {
            try await client.open(request()); Issue.record("Timed out request succeeded")
        } catch let error as MachineUIFailure {
            #expect(error.message == "The owning app window request timed out.")
        }
        #expect(bridge.cancelled.count == 1)
        let tasks = (0..<3).map { _ in Task { try await client.open(request()) } }
        try await wait { bridge.pending.count == 3 }
        client.invalidate()
        for task in tasks {
            do { try await task.value; Issue.record("Disabled request succeeded") } catch {
                #expect(error is MachineUIError)
            }
        }
        #expect(bridge.cancelled.count == 4)
        #expect(bridge.pending.isEmpty)
        let count = bridge.requests.count
        do { try await client.open(request()); Issue.record("Disabled bridge accepted work") } catch
        { #expect(error is MachineUIError) }
        #expect(bridge.requests.count == count)
    }

    @Test func malformedMissingAndOversubscribedBridgesFailBeforeOpening() async throws {
        #expect(MachineHostWindowNavigationClient(bridge: NSObject()) == nil)
        let bridge = MachineNavigationFixture()
        let client = try #require(MachineHostWindowNavigationClient(bridge: bridge))
        var value = request()
        value.presentationID = nil
        do { try await client.open(value); Issue.record("Missing presentation accepted") } catch {
            #expect(error is MachineUIError)
        }
        value = request(); value.path = "/synthetic/invalid-terminal-path"
        do { try await client.open(value); Issue.record("Unexpected path accepted") } catch {
            #expect(error is MachineUIError)
        }
        #expect(bridge.requests.isEmpty)
        let tasks = (0..<8).map { _ in Task { try await client.open(request()) } }
        try await wait { bridge.pending.count == 8 }
        do { try await client.open(request()); Issue.record("Capacity exceeded") } catch {
            #expect(error is MachineUIError)
        }
        #expect(bridge.requests.count == 8)
        client.invalidate()
        for task in tasks { _ = await task.result }
        #expect(bridge.pending.isEmpty)
        #expect(bridge.cancelled.count == 8)
    }

    @Test func synchronousAcknowledgementAndMissingTokenAreHandledOnce() async throws {
        let bridge = MachineNavigationFixture()
        bridge.synchronous = true
        let client = try #require(MachineHostWindowNavigationClient(bridge: bridge))
        try await client.open(request())
        #expect(bridge.cancelled.isEmpty)
        bridge.missingToken = true
        do { try await client.open(request()); Issue.record("Missing token accepted") } catch {
            #expect(error is MachineUIError)
        }
        client.invalidate()
    }

    private func request(kind: MachineHostWindowRequest.Kind = .terminal)
        -> MachineHostWindowRequest
    {
        MachineHostWindowRequest(
            kind: kind, machineID: UUID(),
            path: kind == .files ? "/synthetic/selected-folder" : nil, presentationID: UUID())
    }

    private func wait(_ ready: () -> Bool) async throws {
        let end = ContinuousClock.now.advanced(by: .seconds(2))
        while !ready(), ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(1)) }
        #expect(ready())
    }
}

@MainActor private final class MachineNavigationFixture: NSObject {
    var requests: [NSDictionary] = []
    var pending: [String: (NSString?) -> Void] = [:]
    var cancelled: [String] = []
    var synchronous = false
    var missingToken = false

    @objc(openWindow:completion:)
    func openWindow(_ input: NSDictionary, completion: @escaping (NSString?) -> Void) -> NSString? {
        requests.append(input)
        let token = UUID().uuidString
        if synchronous { completion(nil) } else { pending[token] = completion }
        return missingToken ? nil : token as NSString
    }

    @objc(cancelNavigation:)
    func cancelNavigation(_ token: NSString) {
        cancelled.append(token as String)
        pending.removeValue(forKey: token as String)?("Synthetic cancellation")
    }

    func complete(_ token: String, error: NSString? = nil) {
        pending.removeValue(forKey: token)?(error)
    }
}
