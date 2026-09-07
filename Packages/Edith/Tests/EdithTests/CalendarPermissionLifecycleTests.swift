import Foundation
import Testing

@testable import Edith

@MainActor @Suite struct CalendarPermissionLifecycleTests {
    @Test func sharedObserversCoalesceReadsWithoutPublishingAnOlderStatus() async {
        let entered = CalendarPermissionGate()
        let release = CalendarPermissionGate()
        let calls = CalendarPermissionReadCounter()
        var published: [Bool] = []
        let model = CalendarPermissionModel(
            read: {
                let index = await calls.next()
                if index == 1 {
                    await entered.signal()
                    await release.wait()
                }
                return index != 1
            }, grant: { _ in }, publish: { published.append($0) })
        let first = UUID()
        let second = UUID()
        model.observe(first)
        model.refresh(observer: first)
        await entered.wait()
        model.observe(second)
        for _ in 0..<100 { model.refresh(observer: second) }
        model.stopObserving(first)
        await release.signal()
        await model.waitForRefresh()
        #expect(await calls.count == 2)
        #expect(published == [true])
        model.stopObserving(second)
        model.shutdown()
    }

    @Test func lastObserverReleaseRejectsItsLateResultAfterAnotherWindowOpens() async {
        let entered = CalendarPermissionGate()
        let release = CalendarPermissionGate()
        let calls = CalendarPermissionReadCounter()
        var published: [Bool] = []
        let model = CalendarPermissionModel(
            read: {
                let index = await calls.next()
                if index == 1 {
                    await entered.signal()
                    await release.wait()
                }
                return index == 1
            }, grant: { _ in }, publish: { published.append($0) })
        let closed = UUID()
        model.observe(closed)
        model.refresh(observer: closed)
        await entered.wait()
        model.stopObserving(closed)
        let opened = UUID()
        model.observe(opened)
        model.refresh(observer: opened)
        await release.signal()
        await model.waitForRefresh()
        #expect(published == [false])
        #expect(await calls.count == 2)
        model.stopObserving(opened)
        model.shutdown()
    }

    @Test func anExplicitSettingsReadRemainsOwnedWhenTheLastWindowCloses() async {
        let entered = CalendarPermissionGate()
        let release = CalendarPermissionGate()
        var published: [Bool] = []
        let model = CalendarPermissionModel(
            read: {
                await entered.signal()
                await release.wait()
                return true
            }, grant: { _ in }, publish: { published.append($0) })
        let observer = UUID()
        model.observe(observer)
        model.refresh()
        await entered.wait()
        model.stopObserving(observer)
        await release.signal()
        await model.waitForRefresh()
        #expect(published == [true])
        model.shutdown()
    }

    @Test func repeatedGrantRequestsHaveOneCallbackAndQuitRejectsItsLateReply() async throws {
        var callbacks: [@Sendable () -> Void] = []
        var published: [Bool] = []
        let model = CalendarPermissionModel(
            read: { true }, grant: { callbacks.append($0) }, publish: { published.append($0) })
        for _ in 0..<100 { model.request() }
        #expect(callbacks.count == 1)
        #expect(model.isRequestingPermission)
        model.shutdown()
        callbacks[0]()
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while model.isRequestingPermission {
            guard ContinuousClock.now < deadline else { throw CancellationError() }
            try await Task.sleep(for: .milliseconds(5))
        }
        await model.waitForRefresh()
        #expect(published.isEmpty)
    }
}

private actor CalendarPermissionGate {
    private var signaled = false
    private var continuation: CheckedContinuation<Void, Never>?
    func signal() {
        signaled = true
        continuation?.resume()
        continuation = nil
    }
    func wait() async {
        guard !signaled else { return }
        await withCheckedContinuation { continuation = $0 }
    }
}

private actor CalendarPermissionReadCounter {
    private(set) var count = 0
    func next() -> Int {
        count += 1
        return count
    }
}
