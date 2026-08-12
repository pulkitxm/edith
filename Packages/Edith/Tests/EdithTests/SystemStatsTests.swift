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

    @Test func memoryUsageIncludesAnonymousWiredAndCompressedPages() {
        let used = SystemStatsReader.memoryUsedBytes(
            anonymousPages: 4, wiredPages: 2, compressedPages: 2, pageSize: 1024)
        #expect(used == 8192)
        #expect(SystemStatsReader.memoryUsedPercent(usedBytes: used, totalBytes: 16384) == 50)
    }

    @Test func memoryUsageHandlesUnavailableAndOverflowingTotals() {
        #expect(SystemStatsReader.memoryUsedPercent(usedBytes: 1, totalBytes: 0) == 0)
        #expect(SystemStatsReader.memoryUsedPercent(usedBytes: 2, totalBytes: 1) == 100)
        #expect(
            SystemStatsReader.memoryUsedBytes(
                anonymousPages: UInt64.max, wiredPages: 1, compressedPages: 0, pageSize: 1)
                == UInt64.max)
    }
}
