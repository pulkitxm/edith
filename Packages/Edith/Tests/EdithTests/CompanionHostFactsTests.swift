import Foundation
import Testing

@testable import EdithKit

@Suite struct CompanionHostFactsTests {
    private let thisMac = """
        runtime appleContainer 1.1.0 false none
        os darwin
        arch arm64
        cores 14
        rammb 24576
        diskmb 12348
        gpu Apple M4 Pro
        ports 4820
        """

    private let tuf = """
        runtime docker 29.7.1 true 5.4.0
        os linux
        arch x86_64
        cores 20
        rammb 63918
        diskmb 216127
        gpu\u{20}
        ports 4820 5432 6379
        """

    @Test func aMacWithAStoppedRuntimeIsReadCorrectly() {
        let facts = CompanionHostProbe.parse(thisMac)
        #expect(facts.os == "darwin")
        #expect(facts.arch == "arm64")
        #expect(facts.cpuCores == 14)
        #expect(facts.memoryMb == 24576)
        #expect(facts.gpuModel == "Apple M4 Pro")
        #expect(facts.portsTaken == [4820])
        let runtime = facts.runtime(.appleContainer)
        #expect(runtime?.version == "1.1.0")
        #expect(runtime?.installed == true)
        #expect(runtime?.daemonRunning == false)
        #expect(facts.usableRuntime == nil)
    }

    @Test func aStoppedRuntimeReadsAsStoppedNotMissing() {
        let facts = CompanionHostProbe.parse(thisMac)
        #expect(facts.blockers.contains(.runtimeStopped(.appleContainer)))
        #expect(!facts.blockers.contains(.noRuntime))
    }

    @Test func aLinuxBoxWithDockerCanRunTheStack() {
        let facts = CompanionHostProbe.parse(tuf)
        #expect(facts.cpuCores == 20)
        #expect(facts.diskFreeMb == 216_127)
        #expect(facts.gpuModel == nil)
        #expect(facts.usableRuntime?.kind == .docker)
        #expect(facts.usableRuntime?.composeVersion == "5.4.0")
    }

    @Test func aFailedNvidiaProbeIsNotAGpuName() {
        let facts = CompanionHostProbe.parse(tuf)
        #expect(facts.gpuModel == nil)
    }

    @Test func portsAlreadyServingTheStackAreReportedAsClashes() {
        let facts = CompanionHostProbe.parse(tuf)
        let clash = facts.blockers.first { blocker in
            if case .portsInUse = blocker { return true }
            return false
        }
        #expect(clash == .portsInUse([4820, 5432, 6379]))
    }

    @Test func aHostWithNothingInstalledSaysSo() {
        let facts = CompanionHostProbe.parse(
            """
            os linux
            arch x86_64
            cores 4
            rammb 8192
            diskmb 90000
            gpu\u{20}
            ports
            """)
        #expect(facts.runtimes.isEmpty)
        #expect(facts.blockers.contains(.noRuntime))
        #expect(facts.portsTaken.isEmpty)
    }

    @Test func aFullDiskBlocksBeforeAnythingIsDownloaded() {
        let facts = CompanionHostProbe.parse(
            """
            runtime docker 29.7.1 true 5.4.0
            os linux
            arch x86_64
            cores 4
            rammb 8192
            diskmb 400
            gpu\u{20}
            ports
            """)
        #expect(facts.blockers == [.notEnoughDisk(freeMb: 400, needMb: 12000)])
    }

    @Test func appleContainerCannotRunComposeSoItIsNeverUsable() {
        let facts = CompanionHostProbe.parse(
            """
            runtime appleContainer 1.1.0 true none
            os darwin
            arch arm64
            cores 14
            rammb 24576
            diskmb 90000
            gpu Apple M4 Pro
            ports
            """)
        #expect(facts.runtime(.appleContainer)?.daemonRunning == true)
        #expect(facts.usableRuntime == nil)
    }

    @Test func plainEnglishNamesTheRuntimeSituation() {
        #expect(CompanionHostProbe.parse(tuf).plainEnglish.contains("Docker 29.7.1"))
        #expect(
            CompanionHostProbe.parse(thisMac).plainEnglish
                .contains("Apple Container installed, not running"))
    }
}
