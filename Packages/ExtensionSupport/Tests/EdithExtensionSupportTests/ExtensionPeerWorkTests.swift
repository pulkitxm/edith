import Foundation
import Testing

@testable import EdithExtensionSupport

@Suite @MainActor struct ExtensionPeerWorkTests {
    @Test func slowIOAndItsLateCallbackBothHoldActualRetirement() async throws {
        let work = ExtensionPeerWork()
        work.begin()
        var remaining = 1
        var joined = false
        let retirement = Task {
            await work.closeAndWait(); joined = true
        }
        defer { for _ in 0..<remaining { work.end() } }
        for _ in 0..<100 { await Task.yield() }
        #expect(!joined)
        work.begin()
        remaining += 1
        work.end()
        remaining -= 1
        for _ in 0..<100 { await Task.yield() }
        #expect(!joined)
        work.end()
        remaining -= 1
        let deadline = ContinuousClock.now + .seconds(2)
        while !joined, ContinuousClock.now < deadline { await Task.yield() }
        try #require(joined)
        await retirement.value
    }

    @Test func repeatedWaitersJoinSameOwnedClosure() async throws {
        let work = ExtensionPeerWork()
        work.begin()
        var joinedFirst = false
        var joinedSecond = false
        let first = Task {
            await work.closeAndWait(); joinedFirst = true
        }
        let second = Task {
            await work.closeAndWait(); joinedSecond = true
        }
        for _ in 0..<100 { await Task.yield() }
        #expect(!joinedFirst)
        #expect(!joinedSecond)
        work.end()
        let deadline = ContinuousClock.now + .seconds(2)
        while (!joinedFirst || !joinedSecond), ContinuousClock.now < deadline { await Task.yield() }
        try #require(joinedFirst && joinedSecond)
        await first.value
        await second.value
    }
}
