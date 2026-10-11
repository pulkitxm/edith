import Foundation
import Testing
@testable import StudioExtension

@Suite(.timeLimit(.minutes(1)))
@MainActor struct StudioConcurrencyBoundaryTests {
    @MainActor private final class WeakOwner {
        weak var value: StudioUILongOperations?
        init(_ value: StudioUILongOperations?) { self.value = value }
    }

    @MainActor private final class Work {
        var progress: (@Sendable (Double) -> Void)?
        private var completion: CheckedContinuation<Data, Error>?
        private var ready: CheckedContinuation<Void, Never>?

        func run(_ progress: @escaping @Sendable (Double) -> Void) async throws -> Data {
            self.progress = progress
            return try await withCheckedThrowingContinuation {
                completion = $0
                ready?.resume()
                ready = nil
            }
        }

        func waitForStart() async {
            if completion != nil { return }
            await withCheckedContinuation { ready = $0 }
        }

        func complete() {
            completion?.resume(returning: Data("synthetic".utf8))
            completion = nil
        }
    }

    @Test func tokenScopesInheritRestoreAndKeepConcurrentRequestsSeparate() async throws {
        enum Failure: Error { case expected }
        let first = UUID()
        let second = UUID()
        #expect(StudioUIOperationContext.requestedToken == nil)
        let values = await withTaskGroup(of: UUID?.self) { group in
            for token in [first, second] {
                group.addTask {
                    await StudioUIOperationContext.$requestedToken.withValue(token) {
                        await Task { StudioUIOperationContext.requestedToken }.value
                    }
                }
            }
            var values: [UUID] = []
            for await value in group { if let value { values.append(value) } }
            return values
        }
        #expect(Set(values) == Set([first, second]))
        do {
            try await StudioUIOperationContext.$requestedToken.withValue(first) {
                #expect(StudioUIOperationContext.requestedToken == first)
                #expect(
                    await Task.detached { StudioUIOperationContext.requestedToken }.value == nil)
                throw Failure.expected
            }
        } catch Failure.expected {}
        #expect(StudioUIOperationContext.requestedToken == nil)
    }

    @Test func lateProgressCannotChangeCompletedOrSameTokenReplacementWork() async throws {
        let operations = StudioUILongOperations()
        let (states, updates) = AsyncStream<StudioUIOperationState>.makeStream()
        operations.onChange = { updates.yield($0) }
        let work = Work()
        let token = UUID()
        let started = try StudioUIOperationContext.$requestedToken.withValue(token) {
            try operations.start { try await work.run($0) }
        }
        await work.waitForStart()
        work.progress?(0.8)
        work.progress?(0.2)
        work.progress?(.nan)
        work.complete()
        for await state in states where state.token == started.token {
            if state.phase != "running" { break }
        }
        let handle = try JSONEncoder().encode(["token": started.token.uuidString])
        let completed = try JSONDecoder().decode(
            StudioUIOperationState.self,
            from: operations.invoke("studio.ui.work.read", payload: handle))
        #expect(completed.phase == "completed" && completed.progress == 1)
        _ = try operations.invoke("studio.ui.work.end", payload: handle)
        let replacement = Work()
        let next = try StudioUIOperationContext.$requestedToken.withValue(token) {
            try operations.start { try await replacement.run($0) }
        }
        #expect(next.token == started.token)
        await replacement.waitForStart()
        work.progress?(0.9)
        for _ in 0..<20 { await Task.yield() }
        let nextHandle = try JSONEncoder().encode(["token": next.token.uuidString])
        let current = try JSONDecoder().decode(
            StudioUIOperationState.self,
            from: operations.invoke("studio.ui.work.read", payload: nextHandle))
        #expect(current.phase == "running" && current.progress == 0)
        replacement.progress?(0.25)
        for await state in states where state.token == next.token {
            if state.phase == "running" && state.progress == 0.25 { break }
        }
        let updated = try JSONDecoder().decode(
            StudioUIOperationState.self,
            from: operations.invoke("studio.ui.work.read", payload: nextHandle))
        #expect(updated.phase == "running" && updated.progress == 0.25)
        let stop = Task { await operations.stopAndWait() }
        await Task.yield()
        replacement.complete()
        await stop.value
        work.progress?(1)
    }

    @Test func cancellationDrainsWorkAndProgressDoesNotRetainOwner() async throws {
        var operations: StudioUILongOperations? = StudioUILongOperations()
        let released = WeakOwner(operations)
        let (states, updates) = AsyncStream<StudioUIOperationState>.makeStream()
        operations?.onChange = { updates.yield($0) }
        let work = Work()
        let started = try #require(operations).start { try await work.run($0) }
        await work.waitForStart()
        let handle = try JSONEncoder().encode(["token": started.token.uuidString])
        _ = try operations?.invoke("studio.ui.work.cancel", payload: handle)
        work.complete()
        for await state in states where state.token == started.token {
            if state.phase != "running" { break }
        }
        let data = try #require(try operations?.invoke("studio.ui.work.read", payload: handle))
        #expect(
            try JSONDecoder().decode(StudioUIOperationState.self, from: data).phase == "cancelled")
        await operations?.stopAndWait()
        operations = nil
        #expect(released.value == nil)
        work.progress?(1)
    }
}
