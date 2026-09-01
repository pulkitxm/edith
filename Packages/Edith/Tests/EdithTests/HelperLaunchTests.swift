import Foundation
import Testing
@testable import Edith

@Suite struct HelperLaunchTests {
    @Test func relaunchesHelperRunningFromAnotherAppCopy() {
        let expected = URL(
            fileURLWithPath: "/Applications/Edith.app/Contents/Library/LoginItems/Edith.app")
        let running = URL(fileURLWithPath: "/tmp/Edith.app/Contents/Library/LoginItems/Edith.app")

        #expect(
            shouldRelaunchHelper(
                runningURL: running, expectedURL: expected,
                launchedAt: .now, installedAt: .now) == true)
    }

    @Test func keepsCurrentHelperWhenItIsNewEnough() {
        let expected = URL(
            fileURLWithPath: "/Applications/Edith.app/Contents/Library/LoginItems/Edith.app")
        let installedAt = Date(timeIntervalSince1970: 100)

        #expect(
            shouldRelaunchHelper(
                runningURL: expected, expectedURL: expected,
                launchedAt: installedAt.addingTimeInterval(1), installedAt: installedAt) == false)
    }

    @Test func relaunchesCurrentHelperAfterReplacement() {
        let expected = URL(
            fileURLWithPath: "/Applications/Edith.app/Contents/Library/LoginItems/Edith.app")
        let installedAt = Date(timeIntervalSince1970: 100)

        #expect(
            shouldRelaunchHelper(
                runningURL: expected, expectedURL: expected,
                launchedAt: installedAt.addingTimeInterval(-1), installedAt: installedAt) == true)
    }
}
