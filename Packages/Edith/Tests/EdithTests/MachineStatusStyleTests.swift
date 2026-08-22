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
}
