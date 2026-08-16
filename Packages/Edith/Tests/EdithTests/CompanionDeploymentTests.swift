import Foundation
import Testing

@testable import EdithKit

@Suite struct CompanionDeploymentTests {
    private func facts(
        os: String = "linux", gpu: String? = nil, ports: [Int] = [],
        runtimes: [CompanionRuntimeStatus] = [
            CompanionRuntimeStatus(
                kind: .docker, version: "29.7.1", daemonRunning: true, composeVersion: "5.4.0")
        ]
    ) -> CompanionHostFacts {
        CompanionHostFacts(
            os: os, arch: "x86_64", cpuCores: 20, memoryMb: 63918, diskFreeMb: 216_127,
            gpuModel: gpu, runtimes: runtimes, portsTaken: ports)
    }

    @Test func aHomeRelativeDirectoryStaysExpandable() {
        let command = CompanionStackCommands.ps(directory: "~/edith-companion", tier: .cpu)
        #expect(command.contains("cd \"$HOME\"/edith-companion"))
        #expect(!command.contains("'~/edith-companion'"))
    }

    @Test func anAbsoluteDirectoryIsQuotedNormally() {
        let command = CompanionStackCommands.ps(directory: "/srv/companion stack", tier: .cpu)
        #expect(command.contains("cd '/srv/companion stack'"))
    }

    @Test func eachTierPicksItsOwnComposeOverlay() {
        #expect(CompanionTier.cpu.composeFiles == ["compose.yaml", "compose.cpu.yaml"])
        #expect(CompanionTier.gpu.composeFiles == ["compose.yaml", "compose.gpu.yaml"])
        #expect(CompanionTier.appleMetal.composeFiles == ["compose.yaml", "compose.mac.yaml"])
        let up = CompanionStackCommands.up(directory: "/x", tier: .gpu, build: true)
        #expect(up.contains("-f compose.yaml -f compose.gpu.yaml"))
        #expect(up.contains("-p edith-companion up -d --build"))
    }

    @Test func tierFollowsWhatTheHostActuallyHas() {
        #expect(CompanionTier.derive(from: facts()) == .cpu)
        #expect(CompanionTier.derive(from: facts(gpu: "NVIDIA RTX 4090")) == .gpu)
        #expect(CompanionTier.derive(from: facts(os: "darwin")) == .appleMetal)
    }

    @Test func takingTheStackDownKeepsDataUnlessAsked() {
        #expect(
            CompanionStackCommands.down(directory: "/x", tier: .cpu, keepData: true)
                .hasSuffix("down"))
        #expect(
            CompanionStackCommands.down(directory: "/x", tier: .cpu, keepData: false)
                .hasSuffix("down -v"))
    }

    @Test func composeStatusParsesIntoServices() {
        let services = CompanionStackParsing.services(
            """
            SERVICE\tSTATUS\tPORTS
            api\tUp 28 minutes\t127.0.0.1:4820->4820/tcp
            postgres\tUp About an hour (healthy)\t127.0.0.1:5432->5432/tcp
            whisper\tExited (1)\t
            """)
        #expect(services.count == 3)
        #expect(services[0].service == "api")
        #expect(services[0].running)
        #expect(services[2].service == "whisper")
        #expect(!services[2].running)
    }

    @Test func theHostAlreadyRunningTheStackIsNotBlockedByItsOwnPorts() {
        let busy = facts(ports: [4820, 5432, 6379])
        let candidate = CompanionHost(
            id: UUID(), name: "TUF", target: "p@h", isLocal: false, reachable: true,
            facts: busy, hostsTheStack: false)
        #expect(!candidate.canHostTheStack)
        let hosting = CompanionHost(
            id: candidate.id, name: "TUF", target: "p@h", isLocal: false, reachable: true,
            facts: busy, hostsTheStack: true)
        #expect(hosting.canHostTheStack)
    }

    @Test func thisMacIsAlwaysOfferedFirstEvenWhenNothingIsConnected() {
        let local = CompanionHost(
            id: UUID(), name: "This Mac", target: "this Mac", isLocal: true, reachable: true,
            facts: facts(os: "darwin", runtimes: []))
        let hosts = CompanionHostList.ordered(local: local, machines: [], deployment: nil)
        #expect(hosts.count == 1)
        #expect(hosts[0].isLocal)
        #expect(!hosts[0].canHostTheStack)
        #expect(
            CompanionHostList.emptyStateMessage(hosts)
                == "None of your machines can run it yet. Each one below says what it needs.")
    }

    @Test func theDeployedHostIsMarkedInTheList() {
        let machineID = UUID()
        let local = CompanionHost(
            id: UUID(), name: "This Mac", target: "this Mac", isLocal: true, reachable: true,
            facts: facts(os: "darwin", runtimes: []))
        let remote = CompanionHost(
            id: machineID, name: "TUF", target: "p@h", isLocal: false, reachable: true,
            facts: facts())
        let deployment = CompanionDeployment(
            machineID: machineID, machineName: "TUF", tier: CompanionTier.cpu.rawValue)
        let hosts = CompanionHostList.ordered(
            local: local, machines: [remote], deployment: deployment)
        #expect(hosts[0].isLocal)
        #expect(!hosts[0].hostsTheStack)
        #expect(hosts[1].hostsTheStack)
        #expect(CompanionHostList.recommended(hosts)?.id == machineID)
    }

    @Test func anUnreachableMachineSaysSoRatherThanLookingReady() {
        let offline = CompanionHost(
            id: UUID(), name: "Studio", target: "p@s", isLocal: false, reachable: false,
            facts: nil)
        #expect(!offline.canHostTheStack)
        #expect(offline.blockers == [.unreachable("not reachable")])
        #expect(offline.summary == "not reachable")
    }

    @Test func aDeploymentRoundTripsThroughItsStore() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("companion-deployment-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let deployment = CompanionDeployment(
            machineID: UUID(), machineName: "TUF Wired", tier: "cpu", localPort: 4820)
        CompanionDeploymentStore.save(deployment, to: url)
        let loaded = CompanionDeploymentStore.load(url)
        #expect(loaded?.machineName == "TUF Wired")
        #expect(loaded?.endpoint.absoluteString == "http://127.0.0.1:4820")
        #expect(loaded?.isLocal == false)
    }

    @Test func aMissingDeploymentIsNotAnError() {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("absent-\(UUID().uuidString).json")
        #expect(CompanionDeploymentStore.load(url) == nil)
    }
}
