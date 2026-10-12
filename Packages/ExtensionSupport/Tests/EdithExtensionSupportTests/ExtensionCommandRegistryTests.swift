import Foundation
import Testing
@testable import EdithExtensionSupport

private actor CommandCleanupGate {
    private var waiter: CheckedContinuation<Void, Never>?
    private(set) var entered = false
    func pause() async {
        entered = true
        await withCheckedContinuation { waiter = $0 }
    }
    func release() { waiter?.resume(); waiter = nil }
}

@MainActor @Suite struct ExtensionCommandRegistryTests {
    #if EDITH_FUNCTIONAL_FIXTURE
    @Test(arguments: [false, true])
    func cancellationAndRetirementStartObserveActualPendingOwner(cancelAll: Bool) async throws {
        let registry = ExtensionCommandRegistry()
        let token = UUID()
        var owner: CheckedContinuation<Void, Never>?
        var completed = 0
        var events: [String] = []
        var wasCancelled = false
        let cancelObserver = NotificationCenter.default.addObserver(
            forName: ExtensionCommandRegistry.commandCancelledNotification, object: registry,
            queue: nil
        ) { notification in
            MainActor.assumeIsolated {
                #expect(notification.userInfo?["token"] as? String == token.uuidString)
                #expect(completed == 0)
                events.append("cancelled")
            }
        }
        let startObserver = NotificationCenter.default.addObserver(
            forName: ExtensionCommandRegistry.retirementStartedNotification, object: registry,
            queue: nil
        ) { notification in
            MainActor.assumeIsolated {
                #expect(notification.userInfo?["tokens"] as? [String] == [token.uuidString])
                #expect(completed == 1)
                #expect(owner != nil)
                events.append("started")
            }
        }
        let joinedObserver = NotificationCenter.default.addObserver(
            forName: ExtensionCommandRegistry.ownerJoinedNotification, object: registry, queue: nil
        ) { notification in
            MainActor.assumeIsolated {
                #expect(notification.userInfo?["token"] as? String == token.uuidString)
                #expect(owner == nil)
                events.append("joined")
            }
        }
        defer {
            for observer in [cancelObserver, startObserver, joinedObserver] {
                NotificationCenter.default.removeObserver(observer)
            }
            owner?.resume()
        }
        registry.invoke(
            ["token": token.uuidString, "command": "synthetic.hold", "payload": Data()],
            completion: { _, message in
                #expect(message != nil)
                completed += 1
            },
            execute: { _, _ in
                await withCheckedContinuation { owner = $0 }
                wasCancelled = Task.isCancelled
                return Data()
            })
        let entered = ContinuousClock.now + .seconds(2)
        while owner == nil, ContinuousClock.now < entered { await Task.yield() }
        try #require(owner != nil)
        if cancelAll {
            registry.shutdown()
        } else {
            registry.cancel(token.uuidString)
        }
        registry.cancel(token.uuidString)
        #expect(completed == 1)
        #expect(events == ["cancelled"])
        let join = Task { await registry.shutdownAndWait() }
        let started = ContinuousClock.now + .seconds(2)
        while registry.pendingJoins == 0, ContinuousClock.now < started { await Task.yield() }
        try #require(registry.pendingJoins == 1)
        #expect(events == ["cancelled", "started"])
        owner?.resume()
        owner = nil
        await join.value
        #expect(wasCancelled)
        #expect(completed == 1)
        #expect(events == ["cancelled", "started", "joined"])
    }

    @Test func naturalJoinStartsWithoutInventingCancellation() async throws {
        let registry = ExtensionCommandRegistry()
        let token = UUID()
        var owner: CheckedContinuation<Void, Never>?
        var started = false
        var cancelled = false
        var result: Data?
        let cancelObserver = NotificationCenter.default.addObserver(
            forName: ExtensionCommandRegistry.commandCancelledNotification, object: registry,
            queue: nil
        ) { _ in MainActor.assumeIsolated { cancelled = true } }
        let startObserver = NotificationCenter.default.addObserver(
            forName: ExtensionCommandRegistry.retirementStartedNotification, object: registry,
            queue: nil
        ) { notification in
            MainActor.assumeIsolated {
                #expect(notification.userInfo?["tokens"] as? [String] == [token.uuidString])
                #expect(owner != nil && result == nil)
                started = true
            }
        }
        defer {
            NotificationCenter.default.removeObserver(cancelObserver)
            NotificationCenter.default.removeObserver(startObserver)
            owner?.resume()
        }
        registry.invoke(
            ["token": token.uuidString, "command": "synthetic.hold", "payload": Data()],
            completion: { bytes, message in
                #expect(message == nil)
                result = bytes as Data?
            },
            execute: { _, _ in
                await withCheckedContinuation { owner = $0 }
                #expect(!Task.isCancelled)
                return Data("original-result".utf8)
            })
        let entered = ContinuousClock.now + .seconds(2)
        while owner == nil, ContinuousClock.now < entered { await Task.yield() }
        try #require(owner != nil)
        let join = Task { await registry.closeAdmissionAndWait() }
        let deadline = ContinuousClock.now + .seconds(2)
        while !started, ContinuousClock.now < deadline { await Task.yield() }
        try #require(started)
        #expect(!cancelled)
        owner?.resume()
        owner = nil
        let suspension = await join.value
        #expect(result == Data("original-result".utf8))
        #expect(!cancelled)
        #expect(registry.resume(suspension))
    }

    @Test func retirementEventWaitsForActualOwnerTaskAfterCallerCancellation() async throws {
        let registry = ExtensionCommandRegistry()
        let token = UUID()
        var owner: CheckedContinuation<Void, Never>?
        var callbackReturned = false
        var joined = 0
        let observer = NotificationCenter.default.addObserver(
            forName: ExtensionCommandRegistry.ownerJoinedNotification, object: registry, queue: nil
        ) { notification in
            MainActor.assumeIsolated {
                #expect(notification.userInfo?["token"] as? String == token.uuidString)
                joined += 1
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        registry.invoke(
            ["token": token.uuidString, "command": "synthetic.hold", "payload": Data()],
            completion: { _, _ in callbackReturned = true },
            execute: { _, _ in
                await withCheckedContinuation { owner = $0 }
                return Data()
            })
        let ownerDeadline = ContinuousClock.now + .seconds(2)
        while owner == nil, ContinuousClock.now < ownerDeadline { await Task.yield() }
        try #require(owner != nil)
        defer { owner?.resume() }
        registry.cancel(token.uuidString)
        #expect(callbackReturned)
        var suspensionCompleted = false
        let suspension = Task {
            let result = await registry.suspendAndWait()
            suspensionCompleted = true
            return result
        }
        let joinDeadline = ContinuousClock.now + .seconds(2)
        while registry.pendingJoins == 0, ContinuousClock.now < joinDeadline { await Task.yield() }
        try #require(registry.pendingJoins > 0)
        #expect(joined == 0)
        owner?.resume()
        owner = nil
        let completionDeadline = ContinuousClock.now + .seconds(2)
        while !suspensionCompleted, ContinuousClock.now < completionDeadline { await Task.yield() }
        try #require(suspensionCompleted)
        let suspended = await suspension.value
        #expect(joined == 1)
        #expect(registry.resume(suspended))
        await registry.suspendAndWait()
        #expect(joined == 1)
    }
    #endif

    @Test(arguments: [false, true])
    func shutdownAwaitsCancelledCommandCleanup(cancelFirst: Bool) async throws {
        let registry = ExtensionCommandRegistry()
        let gate = CommandCleanupGate()
        let token = UUID().uuidString
        var entered = false
        var completed = 0
        registry.invoke(
            ["token": token, "command": "fixture", "payload": Data()] as NSDictionary,
            completion: { data, error in
                #expect(data == nil)
                #expect(error != nil)
                completed += 1
            }
        ) { _, _ in
            entered = true
            do { try await Task.sleep(for: .seconds(30)) } catch { await gate.pause(); throw error }
            return Data()
        }
        for _ in 0..<100 where !entered { try await Task.sleep(for: .milliseconds(2)) }
        #expect(entered)
        if cancelFirst { registry.cancel(token) }
        var stopped = false
        let shutdown = Task {
            await registry.shutdownAndWait(); stopped = true
        }
        for _ in 0..<100 {
            if await gate.entered { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(await gate.entered)
        #expect(!stopped)
        #expect(completed == 1)
        await gate.release()
        await shutdown.value
        #expect(stopped)
        #expect(completed == 1)
        var ranAfterStop = false
        registry.invoke(
            ["token": UUID().uuidString, "command": "fixture", "payload": Data()] as NSDictionary,
            completion: { data, error in
                #expect(data == nil)
                #expect(error != nil)
            }
        ) { _, _ in
            ranAfterStop = true; return Data()
        }
        #expect(!ranAfterStop)
    }
    @Test func cancelledCommandsRetainAdmissionUntilTheirCleanupFinishes() async throws {
        let registry = ExtensionCommandRegistry()
        let gates = (0..<8).map { _ in CommandCleanupGate() }
        let tokens = (0..<8).map { _ in UUID().uuidString }
        for (token, gate) in zip(tokens, gates) {
            registry.invoke(
                ["token": token, "command": "fixture", "payload": Data()] as NSDictionary,
                completion: { _, _ in }
            ) { _, _ in
                await gate.pause()
                return Data()
            }
        }
        for gate in gates {
            for _ in 0..<100 {
                if await gate.entered { break }
                try await Task.sleep(for: .milliseconds(2))
            }
            #expect(await gate.entered)
        }
        for token in tokens { registry.cancel(token) }
        var rejected = 0
        var unexpected = false
        for token in [tokens[0], UUID().uuidString] {
            registry.invoke(
                ["token": token, "command": "fixture", "payload": Data()] as NSDictionary,
                completion: { data, error in
                    #expect(data == nil)
                    #expect(error != nil)
                    rejected += 1
                }
            ) { _, _ in
                unexpected = true
                return Data()
            }
        }
        #expect(rejected == 2)
        #expect(!unexpected)
        for gate in gates { await gate.release() }
        await registry.shutdownAndWait()
        #expect(!unexpected)
    }

    @Test func suspensionJoinsActualOwnerAfterCallerCancellationAndAllowsSafeRetry() async throws {
        let registry = ExtensionCommandRegistry()
        let gate = CommandCleanupGate()
        let token = UUID().uuidString
        var callerCompleted = false
        var ownerExited = false
        registry.invoke(
            ["token": token, "command": "fixture", "payload": Data()] as NSDictionary,
            completion: { _, _ in callerCompleted = true }
        ) { _, _ in
            await gate.pause()
            ownerExited = true
            return Data()
        }
        while !(await gate.entered) { await Task.yield() }
        registry.cancel(token)
        #expect(callerCompleted)
        #expect(!ownerExited)
        let suspension = registry.suspend()
        #expect(!registry.resume(suspension))
        var drained = false
        let drain = Task {
            await registry.suspendAndWait(); drained = true
        }
        await Task.yield()
        #expect(!drained)
        var admitted = false
        registry.invoke(
            ["token": UUID().uuidString, "command": "fixture", "payload": Data()] as NSDictionary,
            completion: { data, error in #expect(data == nil && error != nil) }
        ) { _, _ in
            admitted = true; return Data()
        }
        #expect(!admitted)
        await gate.release()
        await drain.value
        #expect(ownerExited)
        #expect(registry.resume(suspension))
        let next = registry.suspend()
        #expect(next != suspension)
        #expect(!registry.resume(suspension))
        #expect(registry.resume(next))
        var result: Data?
        registry.invoke(
            ["token": UUID().uuidString, "command": "fixture", "payload": Data()] as NSDictionary,
            completion: { data, error in
                result = data as Data?; #expect(error == nil)
            }
        ) { _, _ in Data("original-result".utf8) }
        while result == nil { await Task.yield() }
        #expect(result == Data("original-result".utf8))
        let final = registry.suspend()
        await registry.shutdownAndWait()
        #expect(!registry.resume(final))
    }

    @Test func naturalAdmissionJoinPreservesActualOwnerResultWithoutCancellation() async throws {
        let registry = ExtensionCommandRegistry()
        var gate: CheckedContinuation<Void, Never>?
        var wasCancelled = false
        var result: Data?
        var joined = false
        let token = UUID().uuidString
        registry.invoke(
            ["token": token, "command": "fixture", "payload": Data()] as NSDictionary,
            completion: { data, error in
                result = data as Data?; #expect(error == nil)
            }
        ) { _, _ in
            await withCheckedContinuation { gate = $0 }
            wasCancelled = Task.isCancelled
            return Data("owned-result".utf8)
        }
        defer { gate?.resume() }
        let ready = ContinuousClock.now + .seconds(2)
        while gate == nil, ContinuousClock.now < ready { await Task.yield() }
        try #require(gate != nil)
        let suspension = registry.closeAdmission()
        let drain = Task {
            await registry.closeAdmissionAndWait(); joined = true
        }
        for _ in 0..<100 { await Task.yield() }
        #expect(!joined && result == nil)
        #expect(!registry.resume(suspension))
        var rejected = false
        registry.invoke(
            ["token": UUID().uuidString, "command": "fixture", "payload": Data()] as NSDictionary,
            completion: { data, error in rejected = data == nil && error != nil }
        ) { _, _ in
            Issue.record("Closed admission executed new work"); return Data()
        }
        #expect(rejected)
        gate?.resume()
        gate = nil
        let finished = ContinuousClock.now + .seconds(2)
        while !joined, ContinuousClock.now < finished { await Task.yield() }
        try #require(joined)
        await drain.value
        #expect(!wasCancelled)
        #expect(result == Data("owned-result".utf8))
        #expect(registry.resume(suspension))
    }

    @Test func callerCompletionCannotResumeBeforeActualRegistryTaskReturn() async throws {
        let registry = ExtensionCommandRegistry()
        var suspension: UUID?
        var completed = false
        var resumedEarly = false
        registry.invoke(
            ["token": UUID().uuidString, "command": "fixture", "payload": Data()] as NSDictionary,
            completion: { _, _ in
                if let suspension { resumedEarly = registry.resume(suspension) }
                completed = true
            }
        ) { _, _ in Data("owned-result".utf8) }
        suspension = registry.closeAdmission()
        await registry.closeAdmissionAndWait()
        #expect(completed)
        #expect(!resumedEarly)
        #expect(registry.resume(try #require(suspension)))
    }

}
