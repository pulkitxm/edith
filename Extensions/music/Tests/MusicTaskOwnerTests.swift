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
