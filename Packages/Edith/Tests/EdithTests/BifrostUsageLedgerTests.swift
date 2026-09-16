import Foundation
import Testing

@testable import EdithKit

@Suite struct BifrostUsageLedgerTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func recordingCountsAndRanksByRecentUse() {
        var ledger = BifrostUsageLedger()
        ledger.record("app:/a.app", at: now.addingTimeInterval(-86_400 * 60))
        ledger.record("app:/a.app", at: now.addingTimeInterval(-86_400 * 60))
        ledger.record("app:/b.app", at: now)

        #expect(ledger.ranked(now: now, limit: 5) == ["app:/b.app", "app:/a.app"])
    }

    @Test func useDecaysWithTime() {
        var ledger = BifrostUsageLedger()
        ledger.record("app:/a.app", at: now)
        let fresh = ledger.boost(for: "app:/a.app", now: now)
        let stale = ledger.boost(
            for: "app:/a.app", now: now.addingTimeInterval(86_400 * 365))

        #expect(fresh > stale)
        #expect(stale >= 0)
    }

    @Test func theBoostIsCapped() {
        var ledger = BifrostUsageLedger()
        for _ in 0..<5000 { ledger.record("app:/a.app", at: now) }

        #expect(ledger.boost(for: "app:/a.app", now: now) == BifrostUsageLedger.scoreCeiling)
    }

    @Test func anUnknownTargetHasNoBoost() {
        #expect(BifrostUsageLedger().boost(for: "app:/a.app", now: now) == 0)
    }

    @Test func theLedgerStaysWithinItsCapacityAndKeepsTheNewestEntry() {
        var ledger = BifrostUsageLedger()
        for index in 0..<(BifrostUsageLedger.capacity + 20) {
            ledger.record("app:/\(index).app", at: now.addingTimeInterval(Double(index)))
        }

        #expect(ledger.entries.count <= BifrostUsageLedger.capacity)
        #expect(ledger.entries.contains { $0.target == "app:/319.app" })
    }

    @Test func forgettingAndClearingRemoveEntries() {
        var ledger = BifrostUsageLedger()
        ledger.record("app:/a.app", at: now)
        ledger.record("app:/b.app", at: now)

        ledger.forget("app:/a.app")
        #expect(ledger.entries.map(\.target) == ["app:/b.app"])

        ledger.clear()
        #expect(ledger.entries.isEmpty)
    }

    @Test func theLedgerRoundTripsThroughDefaults() {
        let suiteName = "BifrostUsageLedgerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var ledger = BifrostUsageLedger()
        ledger.record("app:/a.app", at: now)

        ledger.save(to: defaults, key: "bifrostUsage")

        #expect(BifrostUsageLedger.load(from: defaults, key: "bifrostUsage") == ledger)
        #expect(BifrostUsageLedger.load(from: defaults, key: "missing").entries.isEmpty)
    }
}
