import Foundation
import Testing

@testable import Edith

@Suite struct ExecutableLaunchTests {
    @Test func normalLaunchStartsTheApplication() {
        #expect(ExecutableLaunch.isApplication(environment: [:]))
    }

    @Test func commandLineLauncherStartsTheCLI() {
        #expect(!ExecutableLaunch.isApplication(environment: ["EDITH_CLI": "1"]))
    }

    @Test(arguments: ["", "0", "true", "yes"])
    func unrelatedValuesStartTheApplication(value: String) {
        #expect(ExecutableLaunch.isApplication(environment: ["EDITH_CLI": value]))
    }
}
