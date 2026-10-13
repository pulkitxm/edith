import Foundation
import Testing

@testable import MusicExtension

extension MusicExtensionTests {
    @MainActor @Suite struct MusicTaskOwnerTests {
        @Test func disablingCancelsDetachedWorkAndRejectsNewWork() async throws {
            let owner = MusicTaskOwner()
            let state = State()
            owner.start {
                await MusicTaskOwner.detached {
                    state.begin()
                    do { try await Task.sleep(for: .seconds(30)) } catch { state.cancel() }
                }
            }
            try await eventually { state.started }
            owner.shutdown()
            try await eventually { state.cancelled }
            owner.start { state.fail() }
            try await Task.sleep(for: .milliseconds(10))
            #expect(!state.failed)
            owner.shutdown()
        }

        @Test func shutdownWaitsForCancelledWorkAndRejectsItsSuccessor() async throws {
            let owner = MusicTaskOwner()
            let gate = MusicTaskGate()
            var successor = false
            owner.start {
                await gate.hold()
                owner.start { successor = true }
            }
            defer {
                gate.release()
                owner.shutdown()
            }
            do {
                try await eventually { gate.entered }
                var draining = false
                var joined = false
                let drain = Task {
                    draining = true
                    await owner.shutdownAndWait()
                    joined = true
                }
                do {
                    try await eventually { draining }
                    #expect(!gate.returned && !joined)
                    gate.release()
                    await drain.value
                    #expect(gate.returned && gate.cancelled && joined)
                    #expect(!successor)
                    await owner.shutdownAndWait()
                } catch {
                    gate.release()
                    owner.shutdown()
                    await drain.value
                    throw error
                }
            } catch {
                gate.release()
                await owner.shutdownAndWait()
                throw error
            }
        }

        @Test func stoppedOwnerRetainsRetiredWorkUntilEveryShutdownFollowerJoins() async throws {
            let owner = MusicTaskOwner()
            let gate = MusicTaskGate()
            let work = Task { await gate.hold() }
            owner.shutdown()
            defer { gate.release(); work.cancel(); owner.shutdown() }
            do {
                try await eventually { gate.entered }
                try #require(gate.entered)
                owner.cancelAndRetain(work)
                var started = 0
                var joined = 0
                var followerCancelled = false
                let first = Task {
                    started += 1
                    await owner.shutdownAndWait()
                    joined += 1
                }
                let follower = Task {
                    started += 1
                    await owner.shutdownAndWait()
                    followerCancelled = Task.isCancelled
                    joined += 1
                }
                do {
                    try await eventually { started == 2 }
                    try #require(started == 2)
                    follower.cancel()
                    #expect(joined == 0 && !gate.returned)
                    gate.release()
                    await first.value
                    await follower.value
                    #expect(joined == 2 && followerCancelled)
                    #expect(gate.returned && gate.cancelled)
                    await owner.shutdownAndWait()
                } catch {
                    gate.release()
                    await first.value
                    await follower.value
                    throw error
                }
            } catch {
                gate.release()
                await work.value
                await owner.shutdownAndWait()
                throw error
            }
        }

        @Test func cancellationBeforeGateAdmissionConsumesNoPermit() async {
            let gate = LoadGate(limit: 3)
            let cancelled = Task { await gate.acquire() }
            cancelled.cancel()
            #expect(await cancelled.value == false)
            for _ in 0..<3 { #expect(await gate.acquire()) }
            for _ in 0..<3 { await gate.release() }
        }

        @Test func queuedCancellationRemovesOnlyItsWaiterAndPreservesThreePermits() async throws {
            let gate = LoadGate(limit: 3)
            for _ in 0..<3 { try #require(await gate.acquire()) }
            let cancelled = Task { await gate.acquire() }
            let live = Task { await gate.acquire() }
            var originalPermits = 3
            var liveReleased = false
            do {
                for _ in 0..<100 {
                    if await gate.queuedCount == 2 { break }
                    try await Task.sleep(for: .milliseconds(10))
                }
                try #require(await gate.queuedCount == 2)
                cancelled.cancel()
                #expect(await cancelled.value == false)
                #expect(await gate.queuedCount == 1)
                await gate.release()
                originalPermits -= 1
                #expect(await live.value)
                await gate.release()
                liveReleased = true
                while originalPermits > 0 {
                    await gate.release()
                    originalPermits -= 1
                }
                try #require(await gate.acquire())
                await gate.release()
            } catch {
                cancelled.cancel(); live.cancel()
                _ = await cancelled.value
                if await live.value, !liveReleased { await gate.release() }
                while originalPermits > 0 {
                    await gate.release()
                    originalPermits -= 1
                }
                throw error
            }
        }

        @Test func cancellationAfterAdmissionRestoresCapacityForThreeSimultaneousLoads()
            async throws
        {
            let gate = LoadGate(limit: 3)
            let held = MusicTaskGate()
            let work = Task {
                guard await gate.acquire() else { return false }
                await held.hold()
                await gate.release()
                return true
            }
            defer { held.release(); work.cancel() }
            do {
                try await eventually { held.entered }
                try #require(held.entered)
                work.cancel(); held.release()
                #expect(await work.value)
                #expect(held.cancelled)
                let probes = [MusicTaskGate(), MusicTaskGate(), MusicTaskGate()]
                let loads = probes.map { probe in
                    Task {
                        guard await gate.acquire() else { return false }
                        await probe.hold()
                        await gate.release()
                        return true
                    }
                }
                do {
                    try await eventually { probes.allSatisfy(\.entered) }
                    let allEntered = probes.allSatisfy(\.entered)
                    try #require(allEntered)
                    for probe in probes { probe.release() }
                    for load in loads { #expect(await load.value) }
                } catch {
                    for load in loads { load.cancel() }
                    for probe in probes { probe.release() }
                    for load in loads { _ = await load.value }
                    throw error
                }
            } catch {
                held.release(); work.cancel()
                _ = await work.value
                throw error
            }
        }

        @Test func joinedCancellationDoesNotReturnUntilItsActorCleanupFinishes() async throws {
            let operation = MusicTaskGate()
            let cancellation = MusicTaskGate()
            var returned = false
            let work = Task {
                let value = await MusicTaskOwner.withJoinedCancellation {
                    await operation.hold()
                    return 19
                } onCancel: {
                    await cancellation.hold()
                }
                #expect(value == 19 && Task.isCancelled)
                returned = true
            }
            defer { operation.release(); cancellation.release(); work.cancel() }
            do {
                try await eventually { operation.entered }
                try #require(operation.entered)
                work.cancel()
                try await eventually { cancellation.entered }
                try #require(cancellation.entered)
                operation.release()
                try await eventually { operation.returned }
                #expect(!returned)
                cancellation.release()
                await work.value
                #expect(returned && cancellation.returned)
            } catch {
                operation.release(); cancellation.release(); work.cancel()
                await work.value
                throw error
            }
        }

        @Test func cancelledDurationDoesNotCacheOrPersistTheLateNativeResult() async throws {
            try #require(ProcessInfo.processInfo.environment["EDITH_EXTENSION_FIXTURE_HOME"] != nil)
            let original = TrackMeta.loadAssetDuration
            let gate = MusicTaskGate()
            let track = Track(
                url: URL(fileURLWithPath: "/tmp/music-retirement-" + UUID().uuidString + ".m4a"))
            TrackMeta.loadAssetDuration = { _ in
                await gate.hold(); return 17.25
            }
            let work = Task { await TrackMeta.duration(for: track) }
            defer { gate.release(); work.cancel(); TrackMeta.loadAssetDuration = original }
            do {
                try await eventually { gate.entered }
                try #require(gate.entered)
                work.cancel()
                gate.release()
                #expect(await work.value == nil)
                #expect(TrackMeta.cachedDurationLabel(for: track) == nil)
                TrackMeta.loadAssetDuration = { _ in 29.25 }
                #expect(await TrackMeta.duration(for: track) == 29.25)
            } catch {
                gate.release(); work.cancel()
                _ = await work.value
                throw error
            }
        }

        private func eventually(_ predicate: () -> Bool) async throws {
            for _ in 0..<100 {
                if predicate() { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(predicate())
        }
    }
}

private final class State: @unchecked Sendable {
    private let lock = NSLock()
    private var began = false
    private var didCancel = false
    private var didFail = false
    var started: Bool { lock.withLock { began } }
    var cancelled: Bool { lock.withLock { didCancel } }
    var failed: Bool { lock.withLock { didFail } }
    func begin() { lock.withLock { began = true } }
    func cancel() { lock.withLock { didCancel = true } }
    func fail() { lock.withLock { didFail = true } }
}

@MainActor private final class MusicTaskGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    private(set) var entered = false
    private(set) var returned = false
    private(set) var cancelled = false

    func hold() async {
        entered = true
        if !released {
            await withCheckedContinuation { continuation = $0 }
        }
        cancelled = Task.isCancelled
        returned = true
    }

    func release() {
        released = true
        let pending = continuation
        continuation = nil
        pending?.resume()
    }
}
