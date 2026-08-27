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

    @Test func monitorCadenceKeepsExpensiveMetricsOffTheFastPath() {
        #expect(SystemMonitorSamplingPolicy.shouldSample(.fast, index: 1))
        #expect(SystemMonitorSamplingPolicy.shouldSample(.gpu, index: 0))
        #expect(!SystemMonitorSamplingPolicy.shouldSample(.gpu, index: 4))
        #expect(SystemMonitorSamplingPolicy.shouldSample(.gpu, index: 5))
        #expect(!SystemMonitorSamplingPolicy.shouldSample(.slow, index: 14))
        #expect(SystemMonitorSamplingPolicy.shouldSample(.slow, index: 15))
    }

    @Test func counterRatesRejectResetsAndLongSamplingGaps() {
        #expect(
            SystemMonitorSampler.bytesPerSecond(previous: 100, current: 300, elapsed: 2) == 100)
        #expect(
            SystemMonitorSampler.bytesPerSecond(previous: 300, current: 100, elapsed: 2) == 0)
        #expect(
            SystemMonitorSampler.bytesPerSecond(previous: 100, current: 300, elapsed: 31) == 0)
    }

    @Test func sustainedGateRequiresFreshReadingsAndRearmsAfterRecovery() {
        var gate = SustainedThresholdGate()
        let initial = gate.evaluate(
            value: 92, threshold: 90, readAt: 10, sustainedSeconds: 12, direction: .atLeast)
        let repeated = gate.evaluate(
            value: 93, threshold: 90, readAt: 10, sustainedSeconds: 12, direction: .atLeast)
        let sustained = gate.evaluate(
            value: 94, threshold: 90, readAt: 22, sustainedSeconds: 12, direction: .atLeast)
        let delivered = gate.evaluate(
            value: 95, threshold: 90, readAt: 40, sustainedSeconds: 12, direction: .atLeast)
        let recovered = gate.evaluate(
            value: 50, threshold: 90, readAt: 42, sustainedSeconds: 12, direction: .atLeast)
        let rearmed = gate.evaluate(
            value: 91, threshold: 90, readAt: 50, sustainedSeconds: 12, direction: .atLeast)
        let second = gate.evaluate(
            value: 91, threshold: 90, readAt: 62, sustainedSeconds: 12, direction: .atLeast)
        #expect(!initial)
        #expect(!repeated)
        #expect(sustained)
        #expect(!delivered)
        #expect(!recovered)
        #expect(!rearmed)
        #expect(second)
    }

    @Test func lowThresholdDirectionHandlesBatteryAlerts() {
        var gate = SustainedThresholdGate()
        let initial = gate.evaluate(
            value: 15, threshold: 20, readAt: 1, sustainedSeconds: 10, direction: .atMost)
        let sustained = gate.evaluate(
            value: 14, threshold: 20, readAt: 11, sustainedSeconds: 10, direction: .atMost)
        #expect(!initial)
        #expect(sustained)
    }
}
