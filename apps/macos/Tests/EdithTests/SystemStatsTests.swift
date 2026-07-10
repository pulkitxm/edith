import Testing

@testable import EdithKit

@Suite struct SystemStatsTests {
    @Test func cpuUsageIsUsedOverTotalDelta() {
        let previous = CPUTicks(used: 100, total: 200)
        let current = CPUTicks(used: 150, total: 300)
        #expect(SystemStatsReader.cpuUsage(previous: previous, current: current) == 50)
    }

    @Test func cpuUsageZeroWhenNoDelta() {
        let ticks = CPUTicks(used: 100, total: 200)
        #expect(SystemStatsReader.cpuUsage(previous: ticks, current: ticks) == 0)
    }

    @Test func cpuUsageClampsToHundred() {
        let previous = CPUTicks(used: 0, total: 0)
        let current = CPUTicks(used: 100, total: 50)
        #expect(SystemStatsReader.cpuUsage(previous: previous, current: current) == 100)
    }
}
