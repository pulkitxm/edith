import Foundation
import Testing

@testable import EdithCLI

private final class SendableCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }

    func read() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

@Suite struct CLIReplyWaiterTests {
    @Test func deliveryBeforeWaitingIsRetained() async {
        let waiter = ReplyWaiter()
        #expect(waiter.deliver(["value": "ready"]))
        let reply = await waiter.wait()
        #expect(reply?["value"] as? String == "ready")
    }

    @Test func deliveryResumesAWaitingCommand() async {
        let waiter = ReplyWaiter()
        let task = Task { await waiter.wait()?["value"] as? Int }
        await Task.yield()
        #expect(waiter.deliver(["value": 42]))
        #expect(await task.value == 42)
    }

    @Test func theFirstReplyWins() async {
        let waiter = ReplyWaiter()
        #expect(waiter.deliver(["value": "first"]))
        #expect(!waiter.deliver(["value": "second"]))
        let reply = await waiter.wait()
        #expect(reply?["value"] as? String == "first")
    }

    @Test func anEmptyReplyIsStillAReply() async {
        let waiter = ReplyWaiter()
        #expect(waiter.deliver([:]))
        #expect(await waiter.wait()?.isEmpty == true)
    }

    @Test func cancellationResumesWithNoReply() async {
        let waiter = ReplyWaiter()
        let task = Task { await waiter.wait() == nil }
        await Task.yield()
        task.cancel()
        #expect(await task.value)
        #expect(waiter.isFinished)
    }

    @Test func cancellationBeforeWaitingIsRetained() async {
        let waiter = ReplyWaiter()
        #expect(waiter.cancel())
        #expect(!waiter.cancel())
        #expect(await waiter.wait() == nil)
    }

    @Test func onlyOneOfManyConcurrentRepliesIsAccepted() async {
        let waiter = ReplyWaiter()
        let accepted = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for value in 0..<200 {
                group.addTask { waiter.deliver(["value": value]) }
            }
            var count = 0
            for await result in group where result { count += 1 }
            return count
        }
        #expect(accepted == 1)
        #expect(await waiter.wait() != nil)
    }

    @Test func independentWaitersDoNotInterfere() async {
        let values = await withTaskGroup(of: Int?.self, returning: [Int].self) { group in
            for value in 0..<100 {
                group.addTask {
                    let waiter = ReplyWaiter()
                    waiter.deliver(["value": value])
                    return await waiter.wait()?["value"] as? Int
                }
            }
            var results: [Int] = []
            for await value in group {
                if let value { results.append(value) }
            }
            return results
        }
        #expect(values.sorted() == Array(0..<100))
    }

    @Test func appReplyTimeoutUsesOneTrigger() async {
        let counter = SendableCounter()
        let reply = await AppBridge.awaitReply(
            Notification.Name("test.reply.\(UUID().uuidString)"), timeout: 0.01
        ) {
            counter.increment()
        }
        #expect(reply == nil)
        #expect(counter.read() == 1)
    }
}
