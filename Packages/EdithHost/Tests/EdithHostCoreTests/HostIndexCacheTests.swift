import Foundation
import Testing

@testable import EdithHostCore

@Suite struct HostIndexCacheTests {
    @Test func repeatedBundledLoadsReturnTheSameEntriesFasterThanTheFirstDecode() throws {
        let first = try HostIndex.bundled()
        let clock = ContinuousClock()
        let elapsed = try clock.measure { for _ in 0..<200 { _ = try HostIndex.bundled() } }
        let second = try HostIndex.bundled()
        #expect(first == second)
        #expect(!first.isEmpty)
        #expect(elapsed < .milliseconds(50))
    }
}
