import Testing

@testable import EdithKit

@Suite struct AgentProcessFilterTests {
    @Test func matchesKnownAgentProcessNames() {
        #expect(AgentProcessFilter.isAgentProcess(name: "claude"))
        #expect(AgentProcessFilter.isAgentProcess(name: "node"))
        #expect(AgentProcessFilter.isAgentProcess(name: "bun"))
        #expect(AgentProcessFilter.isAgentProcess(name: "NODE"))
    }

    @Test func rejectsUnrelatedProcessNames() {
        #expect(!AgentProcessFilter.isAgentProcess(name: "Finder"))
        #expect(!AgentProcessFilter.isAgentProcess(name: "WindowServer"))
        #expect(!AgentProcessFilter.isAgentProcess(name: ""))
    }
}

@Suite struct ProcessUsageTests {
    @Test func cpuPercentIsZeroWithNoElapsedTime() {
        #expect(ProcessUsage.cpuPercent(nowNS: 5, previousNS: 0, elapsed: 0) == 0)
    }

    @Test func cpuPercentComputesDeltaOverElapsed() {
        let oneCoreFullyBusyForASecond = ProcessUsage.cpuPercent(
            nowNS: 1_000_000_000, previousNS: 0, elapsed: 1)
        #expect(oneCoreFullyBusyForASecond == 100)
    }

    @Test func cpuPercentNeverGoesNegative() {
        #expect(ProcessUsage.cpuPercent(nowNS: 0, previousNS: 0, elapsed: 1) == 0)
    }
}
