import Foundation
import Testing

@testable import EdithKit

@Suite @MainActor struct MachineSessionLocalCommandTests {
    private func session() -> MachineSession {
        MachineSession(
            machine: Machine(name: "This Mac", host: "localhost"),
            local: true,
            observesWakeRequests: false)
    }

    @Test func forwardsStandardInput() async {
        let input = "first line\nsecond line\n"
        let result = await session().runCommand(
            "cat", stdin: Data(input.utf8), timeout: 2)

        switch result {
        case let .success(output):
            #expect(output == input)
        case let .failure(error):
            Issue.record(error)
        }
    }

    @Test func terminatesLongRunningCommands() async {
        let result = await session().runCommand("exec sleep 300", timeout: 0.1)
        guard case .failure = result else {
            Issue.record("expected the command to time out")
            return
        }
    }
}
