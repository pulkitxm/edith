import Foundation
import Testing

@testable import EdithKit

@Suite struct BudgetMathTests {
    private let start = Date(timeIntervalSinceReferenceDate: 0)
    private var deadline: Date { start.addingTimeInterval(10 * 86400) }

    @Test func targetRampsLinearlyToCap() {
        let mid = start.addingTimeInterval(5 * 86400)
        #expect(
            LimitMath.budgetTarget(capPercent: 50, start: start, deadline: deadline, now: mid) == 25
        )
    }

    @Test func targetClampsAtCapAfterDeadline() {
        let after = deadline.addingTimeInterval(86400)
        #expect(
            LimitMath.budgetTarget(capPercent: 50, start: start, deadline: deadline, now: after)
                == 50)
    }

    @Test func targetIsZeroAtStart() {
        #expect(
            LimitMath.budgetTarget(capPercent: 50, start: start, deadline: deadline, now: start)
                == 0)
    }

    @Test func onPaceWhenActualNearTarget() {
        let mid = start.addingTimeInterval(5 * 86400)
        let status = LimitMath.budgetStatus(
            actual: 26, capPercent: 50, start: start, deadline: deadline, now: mid)
        #expect(status.state == .onPace)
    }

    @Test func overWhenSpendingTooFast() {
        let mid = start.addingTimeInterval(5 * 86400)
        let status = LimitMath.budgetStatus(
            actual: 40, capPercent: 50, start: start, deadline: deadline, now: mid)
        #expect(status.state == .over)
        #expect(status.deltaIsPositive)
    }

    @Test func underWhenSpendingSlowly() {
        let mid = start.addingTimeInterval(5 * 86400)
        let status = LimitMath.budgetStatus(
            actual: 10, capPercent: 50, start: start, deadline: deadline, now: mid)
        #expect(status.state == .under)
    }

    @Test func exceededWhenAtOrAboveCap() {
        let mid = start.addingTimeInterval(5 * 86400)
        let status = LimitMath.budgetStatus(
            actual: 51, capPercent: 50, start: start, deadline: deadline, now: mid)
        #expect(status.state == .exceeded)
    }

    @Test func dailyBudgetSplitsRemainingOverDaysLeft() {
        let now = start
        let resetsAt = start.addingTimeInterval(4 * 86400)
        let daily = LimitMath.dailyBudget(actual: 20, capPercent: 100, resetsAt: resetsAt, now: now)
        #expect(daily == 20)
    }

    @Test func dailyBudgetNeverDividesByLessThanOneDay() {
        let now = start
        let resetsAt = start.addingTimeInterval(3600)
        let daily = LimitMath.dailyBudget(actual: 40, capPercent: 100, resetsAt: resetsAt, now: now)
        #expect(daily == 60)
    }

    @Test func dailyBudgetIsZeroWhenOverCap() {
        let daily = LimitMath.dailyBudget(
            actual: 120, capPercent: 100, resetsAt: start.addingTimeInterval(86400), now: start)
        #expect(daily == 0)
    }
}

extension BudgetStatus {
    fileprivate var deltaIsPositive: Bool { actualPercent - targetPercent > 0 }
}
