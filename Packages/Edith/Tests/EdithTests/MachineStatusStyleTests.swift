import Foundation
import Testing

@testable import Edith
import EdithKit

@Suite struct MachineStatusStyleTests {
    @Test func failureSummaryDoesNotRepeatTheDetailedReason() {
        let state = MachineConnectionState.failed(
            message: "Edith connects to remote Macs only.", recoverable: false)

        #expect(MachineStatusStyle.label(state) == "Connection failed")
        #expect(MachineStatusStyle.detail(state) == "Edith connects to remote Macs only.")
    }

    @Test func nonFailureDetailsUseTheStatusLabel() {
        #expect(MachineStatusStyle.detail(.disconnected) == "Not connected")
        #expect(MachineStatusStyle.detail(.connected(latencyMillis: nil)) == "Connected")
    }

    @Test func clipboardStatesExposeUsefulStatus() {
        #expect(SSHClipboardSyncState.disabled.label == "Clipboard sync disabled")
        #expect(SSHClipboardSyncState.configuring.symbol == "arrow.triangle.2.circlepath")
        #expect(SSHClipboardSyncState.active.label == "Clipboard sync active")
        #expect(
            SSHClipboardSyncState.failed("offline").label
                == "Clipboard sync failed: offline")
    }

    @Test func queuedRemovalTargetsTheEffectiveEditedMachine() {
        let id = UUID(uuidString: "01010101-0101-0101-0101-010101010101")!
        let submitted = Machine(
            id: id, name: "Tuf", host: "10.0.0.1", username: "pulkit",
            source: .sshConfigAlias("tuf-old"), sshClipboardEnabled: true)
        var edited = submitted
        edited.host = "10.0.0.2"
        edited.source = .sshConfigAlias("tuf-new")

        let previous = MachineMutationReconciliation.previous(
            for: .remove, machineID: id, machines: [edited])
        let target = MachineMutationReconciliation.removalTarget(
            submitted: submitted, effectivePrevious: previous)

        #expect(previous?.source == .sshConfigAlias("tuf-new"))
        #expect(target.host == "10.0.0.2")
        #expect(target.source == .sshConfigAlias("tuf-new"))
        #expect(!target.sshClipboardEnabled)
    }
}
