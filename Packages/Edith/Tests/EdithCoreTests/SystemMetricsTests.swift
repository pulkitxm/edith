import Foundation
import Testing

@testable import EdithCore

struct SystemMetricsTests {
    private let procStat = """
        cpu  100 20 30 800 40 0 10 0 0 0
        cpu0 50 10 15 400 20 0 5 0 0 0
        intr 12345
        """

    private let procMeminfo = """
        MemTotal:       16289940 kB
        MemFree:         1234567 kB
        MemAvailable:    8144970 kB
        Buffers:          123456 kB
        """

    @Test func cpuSampleCountsIdleAndIOWaitAsUnused() {
        let sample = SystemMetricsParsing.cpuSample(fromProcStat: procStat)
        #expect(sample?.total == 1_000)
        #expect(sample?.used == 160)
    }

    @Test func cpuSampleIgnoresFilesWithoutAnAggregateLine() {
        #expect(SystemMetricsParsing.cpuSample(fromProcStat: "cpu0 1 2 3 4\nintr 5") == nil)
    }

    @Test func cpuUsageIsTheFractionOfTheDelta() {
        let previous = CPUSample(used: 100, total: 1_000)
        let current = CPUSample(used: 150, total: 1_200)
        #expect(SystemMetricsParsing.cpuUsage(previous: previous, current: current) == 0.25)
    }

    @Test func cpuUsageIsZeroWhenNoTimePassed() {
        let sample = CPUSample(used: 100, total: 1_000)
        #expect(SystemMetricsParsing.cpuUsage(previous: sample, current: sample) == 0)
    }

    @Test func memorySampleConvertsKilobytesToBytes() {
        let sample = SystemMetricsParsing.memorySample(fromProcMeminfo: procMeminfo)
        #expect(sample?.totalBytes == 16_680_898_560)
        #expect(sample?.availableBytes == 8_340_449_280)
        #expect(sample?.usedBytes == 8_340_449_280)
    }

    @Test func memorySampleNeedsBothFields() {
        #expect(SystemMetricsParsing.memorySample(fromProcMeminfo: "MemTotal: 100 kB") == nil)
    }

    @Test func memoryFractionIsSafeWithoutATotal() {
        #expect(MemorySample(totalBytes: 0, availableBytes: 0).usedFraction == 0)
    }
}
