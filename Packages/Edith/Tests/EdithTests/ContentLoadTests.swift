import Foundation
import Testing
@testable import EdithKit

@MainActor
@Suite struct ContentLoadTests {
    @Test func staleRequestsCannotReplaceNewContentOrErrors() {
        let load = ContentLoad()
        let old = load.begin()
        let current = load.begin()
        load.cancel(old)
        #expect(load.isCurrent(current))
        load.complete(current)
        load.fail(old, message: "Old failure")
        #expect(load.state == .content)
        #expect(load.errorMessage == nil)
        #expect(!load.isRunning)
    }

    @Test func refreshFailureRetainsContentAndCanRecover() {
        let load = ContentLoad()
        load.setContent()
        let request = load.begin()
        #expect(load.isRefreshing)
        #expect(load.state == .content)
        load.fail(request, message: "Try again")
        #expect(load.hasContent)
        #expect(load.state == .content)
        #expect(load.errorMessage == "Try again")
        let retry = load.begin()
        load.complete(retry)
        #expect(load.errorMessage == nil)
    }

    @Test func initialFailureDoesNotPretendSetupIsLoaded() {
        let load = ContentLoad()
        load.fail(load.begin(), message: "Unavailable", offline: true)
        #expect(load.state == .offline)
        #expect(!load.hasContent)
        load.complete(load.begin(), empty: true)
        #expect(load.state == .empty)
    }

    @Test func cancellationInvalidatesOutstandingPublication() {
        let load = ContentLoad()
        let request = load.begin()
        load.cancel()
        load.complete(request)
        #expect(load.state == .cancelled)
        load.setContent()
        let refresh = load.begin()
        load.cancel()
        load.fail(refresh, message: "Late failure")
        #expect(load.state == .content)
        #expect(load.errorMessage == nil)
    }

    @Test func supersededOperationsCannotPublishEvenWhenTheyIgnoreCancellation() async {
        let load = ContentLoad()
        let gate = LoadTestGate()
        var published: [Int] = []
        let old = Task {
            await load.perform(operation: { await gate.wait() }) { published.append($0) }
        }
        await gate.started()
        await load.perform(operation: { 2 }) { published.append($0) }
        await gate.release(1)
        await old.value
        #expect(published == [2])
        #expect(load.state == .content)
    }

    @Test func parentCancellationStopsOwnedWorkAndSuppressesPublication() async {
        let load = ContentLoad()
        let gate = LoadTestGate()
        var published = false
        let task = Task {
            await load.perform(operation: { await gate.wait() }) { _ in published = true }
        }
        await gate.started()
        task.cancel()
        await gate.release(1)
        await task.value
        #expect(!published)
        #expect(load.state == .cancelled)
        #expect(!load.isRunning)
    }
}

private actor LoadTestGate {
    private var continuation: CheckedContinuation<Int, Never>?
    private var startContinuation: CheckedContinuation<Void, Never>?

    func wait() async -> Int {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            startContinuation?.resume()
            startContinuation = nil
        }
    }

    func started() async {
        if continuation != nil { return }
        await withCheckedContinuation { startContinuation = $0 }
    }

    func release(_ value: Int) {
        continuation?.resume(returning: value)
        continuation = nil
    }
}
