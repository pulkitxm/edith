import Foundation
import Testing

@testable import EdithKit

@Suite struct IPCReplyAwaiterTests {
    @Test func unrelatedRepliesCannotWinTheRequest() async {
        let name = Notification.Name("com.pulkit.edith.tests.reply." + UUID().uuidString)
        let reply = await IPCReplyAwaiter.awaitReply(
            name, timeout: 2, matching: { $0["requestID"] as? String == "expected" },
            trigger: {
                let center = DistributedNotificationCenter.default()
                center.postNotificationName(
                    name, object: nil, userInfo: ["requestID": "other"], deliverImmediately: true)
                center.postNotificationName(
                    name, object: nil, userInfo: ["requestID": "expected", "value": "sample"],
                    deliverImmediately: true)
            })
        #expect(reply?["value"] as? String == "sample")
    }

    @Test func timeoutAndCancellationReleaseTheWaiter() async {
        let name = Notification.Name("com.pulkit.edith.tests.reply." + UUID().uuidString)
        #expect(await IPCReplyAwaiter.awaitReply(name, timeout: 0, trigger: {}) == nil)
        let task = Task {
            await IPCReplyAwaiter.awaitReply(name, timeout: 60, trigger: {})?["value"] as? String
        }
        task.cancel()
        #expect(await task.value == nil)
    }
}
