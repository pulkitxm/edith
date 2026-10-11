import Foundation
import Testing

@testable import StudioExtension

@MainActor @Suite(.serialized) struct StudioUILongOperationOwnershipTests {
    @Test func endedRetainedWorkRemainsOwnedUntilItsActualReturn() async throws {
        let work = StudioUILongOperations()
        var entered = false
        var returned = false
        var joined = false
        var joinedAgain = false
        var continuation: CheckedContinuation<Void, Never>?
        var observations: [StudioUIOperationState] = []
        work.onChange = { observations.append($0) }
        let state = try work.start(retained: true) { progress in
            entered = true
            progress(0.2)
            await withCheckedContinuation { continuation = $0 }
            returned = true
            progress(0.9)
            return Data("{}".utf8)
        }
        try await wait { entered && continuation != nil }
        let handle = try JSONSerialization.data(withJSONObject: ["token": state.token.uuidString])
        _ = try work.invoke("studio.ui.work.end", payload: handle)
        work.suspend()
        #expect(throws: (any Error).self) { try work.start { _ in Data() } }
        let first = Task { await work.suspendAndWait(); joined = true }
        let second = Task { await work.suspendAndWait(); joinedAgain = true }
        for _ in 0..<30 { await Task.yield() }
        #expect(!joined && !joinedAgain && !returned)
        continuation?.resume()
        continuation = nil
        try await wait { joined && joinedAgain }
        await first.value
        await second.value
        #expect(joined && joinedAgain && returned)
        #expect(observations.last?.token == state.token)
        #expect(observations.last?.phase == "cancelled")
        let count = observations.count
        for _ in 0..<30 { await Task.yield() }
        #expect(observations.count == count)
        try await stop(work)
    }

    @Test func structuredProgressPreservesCompletedResult() async throws {
        let work = StudioUILongOperations()
        let state = try work.start { progress in
            progress(0.3)
            await Task.yield()
            progress(0.8)
            return Data("{\"result\":1}".utf8)
        }
        let handle = try JSONSerialization.data(withJSONObject: ["token": state.token.uuidString])
        try await wait {
            guard let bytes = try? work.invoke("studio.ui.work.read", payload: handle),
                let value = try? JSONDecoder().decode(StudioUIOperationState.self, from: bytes)
            else { return false }
            return value.phase == "completed"
        }
        let final = try JSONDecoder().decode(
            StudioUIOperationState.self,
            from: work.invoke("studio.ui.work.read", payload: handle))
        #expect(final.progress == 1)
        #expect(final.result == Data("{\"result\":1}".utf8))
        try await stop(work)
    }

    private func stop(_ work: StudioUILongOperations) async throws {
        var joined = false
        let task = Task { await work.stopAndWait(); joined = true }
        try await wait { joined }
        await task.value
    }

    private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition(), ContinuousClock.now < deadline { await Task.yield() }
        guard condition() else { throw CocoaError(.coderInvalidValue) }
    }
}
