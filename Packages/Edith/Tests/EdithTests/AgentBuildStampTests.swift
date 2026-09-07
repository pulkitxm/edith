import Foundation
import Testing

@testable import EdithKit

@Suite struct AgentBuildStampTests {
    @Test func aFirstRunHasNothingRecorded() {
        #expect(AgentBuildStamp.stampIsStale(recorded: nil, current: "228|/Applications|1|2"))
    }

    @Test func aReinstallOfTheSameVersionStillCountsAsStale() {
        let before = AgentBuildStamp.stamp(
            build: "228", bundlePath: "/Applications/Edith.app",
            executableModified: Date(timeIntervalSince1970: 1_000), executableSize: 42)
        let after = AgentBuildStamp.stamp(
            build: "228", bundlePath: "/Applications/Edith.app",
            executableModified: Date(timeIntervalSince1970: 2_000), executableSize: 42)

        #expect(AgentBuildStamp.stampIsStale(recorded: before, current: after))
    }

    @Test func aMovedBundleCountsAsStale() {
        let installed = AgentBuildStamp.stamp(
            build: "228", bundlePath: "/Applications/Edith.app",
            executableModified: Date(timeIntervalSince1970: 1_000), executableSize: 42)
        let elsewhere = AgentBuildStamp.stamp(
            build: "228", bundlePath: "/Users/pulkit/dist/Edith.app",
            executableModified: Date(timeIntervalSince1970: 1_000), executableSize: 42)

        #expect(AgentBuildStamp.stampIsStale(recorded: installed, current: elsewhere))
    }

    @Test func aResizedExecutableCountsAsStale() {
        let before = AgentBuildStamp.stamp(
            build: "228", bundlePath: "/Applications/Edith.app",
            executableModified: Date(timeIntervalSince1970: 1_000), executableSize: 42)
        let after = AgentBuildStamp.stamp(
            build: "228", bundlePath: "/Applications/Edith.app",
            executableModified: Date(timeIntervalSince1970: 1_000), executableSize: 43)

        #expect(AgentBuildStamp.stampIsStale(recorded: before, current: after))
    }

    @Test func anUntouchedInstallIsNotStale() {
        let stamp = AgentBuildStamp.stamp(
            build: "228", bundlePath: "/Applications/Edith.app",
            executableModified: Date(timeIntervalSince1970: 1_000), executableSize: 42)

        #expect(!AgentBuildStamp.stampIsStale(recorded: stamp, current: stamp))
    }

    @Test func aMissingExecutableStillProducesAStamp() {
        let stamp = AgentBuildStamp.stamp(
            build: "228", bundlePath: "/Applications/Edith.app", executableModified: nil,
            executableSize: nil)

        #expect(stamp == "228|/Applications/Edith.app|0|0")
    }

    @Test func theStampPointsAtTheAgentExecutable() {
        let url = AgentBuildStamp.executableURL(bundle: .main)

        #expect(url.lastPathComponent == AgentService.executableName)
        #expect(url.deletingLastPathComponent().lastPathComponent == "MacOS")
    }
}
