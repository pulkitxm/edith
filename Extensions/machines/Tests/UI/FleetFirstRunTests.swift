import Foundation
import Testing

@testable import MachinesExtension

@Suite struct FleetFirstRunTests {
    private func snapshot(local: Bool) -> MachineSnapshot {
        MachineSnapshot(
            id: UUID(), name: local ? "This Mac" : "box", isLocal: local, online: true, cores: 4,
            cpuPercent: 10, memoryTotalKB: 1_000, memoryUsedKB: 100)
    }

    @Test func onlyTheLocalMachineAsksForARemoteOne() {
        #expect(FleetFirstRun.needsRemoteMachine([snapshot(local: true)]))
    }

    @Test func anyRemoteMachineEndsTheFirstRun() {
        #expect(!FleetFirstRun.needsRemoteMachine([snapshot(local: true), snapshot(local: false)]))
    }
}
