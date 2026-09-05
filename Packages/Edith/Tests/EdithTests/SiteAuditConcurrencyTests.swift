import Foundation
import Testing

@testable import EdithAgent
@testable import EdithKit

@Suite struct SiteAuditConcurrencyTests {
    @Test func theCrawlRunsFourWideByDefault() {
        #expect(SiteAuditConcurrency.limit == 4)
    }

    @Test func slotsNeverExceedTheWorkOrTheLimit() {
        #expect(SiteAuditConcurrency.slots(for: 0) == 1)
        #expect(SiteAuditConcurrency.slots(for: 2) == 2)
        #expect(SiteAuditConcurrency.slots(for: 40) == 4)
        #expect(SiteAuditConcurrency.slots(for: 40, limit: 2) == 2)
    }

    @Test func everyElementIsTransformedInOrder() async {
        let input = Array(0..<25)

        let output = await BoundedTaskRunner.map(input, limit: 4) { _, value in
            try? await Task.sleep(for: .milliseconds(UInt64.random(in: 0...3)))
            return value * 2
        }

        #expect(output == input.map { $0 * 2 })
    }

    @Test func noMoreThanTheLimitRunAtOnce() async {
        let counter = ConcurrencyCounter()

        _ = await BoundedTaskRunner.map(Array(0..<30), limit: 4) { _, value in
            counter.enter()
            try? await Task.sleep(for: .milliseconds(2))
            counter.leave()
            return value
        }

        #expect(counter.peak <= 4)
        #expect(counter.peak > 1)
    }

    @Test func anEmptyListDoesNothing() async {
        let output = await BoundedTaskRunner.map([Int](), limit: 4) { _, value in value }
        #expect(output.isEmpty)
    }

}

private final class ConcurrencyCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0
    private var highest = 0

    var peak: Int {
        lock.lock()
        defer { lock.unlock() }
        return highest
    }

    func enter() {
        lock.lock()
        active += 1
        highest = max(highest, active)
        lock.unlock()
    }

    func leave() {
        lock.lock()
        active -= 1
        lock.unlock()
    }
}
