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

        @Test func concurrentShutdownWaitsForCancelledWorkToActuallyReturn() async throws {
            let owner = MusicTaskOwner()
            var entered = false
            var returned = false
            var joined = false
            var joinedAgain = false
            var continuation: CheckedContinuation<Void, Never>?
            let actual = owner.start {
                entered = true
                await withCheckedContinuation { continuation = $0 }
                returned = true
            }
            try await eventually { entered && continuation != nil }
            guard let held = continuation else {
                Issue.record("The owned task did not enter its held operation.")
                owner.shutdown()
                return
            }
            owner.shutdown()
            #expect(actual?.isCancelled == true)
            #expect(owner.start { Issue.record("Shutdown admitted new work.") } == nil)
            let first = Task { await owner.shutdownAndWait(); joined = true }
            let second = Task { await owner.shutdownAndWait(); joinedAgain = true }
            for _ in 0..<30 { await Task.yield() }
            #expect(!joined && !joinedAgain && !returned)
            held.resume()
            continuation = nil
            await first.value
            await second.value
            #expect(joined && joinedAgain && returned)
            await actual?.value
            await owner.shutdownAndWait()
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
