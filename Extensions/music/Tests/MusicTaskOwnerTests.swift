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
