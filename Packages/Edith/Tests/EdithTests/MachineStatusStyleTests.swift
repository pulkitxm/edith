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
}
