import Testing

@testable import EdithKit

@Suite struct PasteQueueTests {
    @Test func startsEmpty() {
        let queue = PasteQueue()
        #expect(queue.isEmpty)
        #expect(queue.count == 0)
    }

    @Test func dequeuesInFIFOOrder() {
        var queue = PasteQueue()
        queue.enqueue("a")
        queue.enqueue("b")
        queue.enqueue("c")
        #expect(queue.count == 3)
        #expect(queue.dequeue() == "a")
        #expect(queue.dequeue() == "b")
        #expect(queue.count == 1)
        #expect(queue.dequeue() == "c")
        #expect(queue.dequeue() == nil)
    }

    @Test func removeDropsAllMatchingEntries() {
        var queue = PasteQueue()
        queue.enqueue("a")
        queue.enqueue("b")
        queue.enqueue("a")
        queue.remove("a")
        #expect(queue.entryIDs == ["b"])
    }

    @Test func clearEmptiesQueue() {
        var queue = PasteQueue()
        queue.enqueue("a")
        queue.clear()
        #expect(queue.isEmpty)
    }
}
