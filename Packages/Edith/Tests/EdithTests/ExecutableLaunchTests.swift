import Foundation
import Testing

@testable import Edith

@Suite struct ExecutableLaunchTests {
    @Test func normalLaunchStartsTheApplication() {
        #expect(ExecutableLaunch.destination(environment: [:]) == .application)
        #expect(ExecutableLaunch.isApplication(environment: [:]))
    }

    @Test func commandLineLauncherStartsTheCLI() {
        #expect(
            ExecutableLaunch.destination(
                environment: ["EDITH_CLI": "1"]
            ) == .commandLine)
        #expect(!ExecutableLaunch.isApplication(environment: ["EDITH_CLI": "1"]))
    }

    @Test func databaseBrokerLauncherTakesPrecedenceOverTheCLI() {
        let environment = [
            "EDITH_DATABASE_BROKER": "1",
            "EDITH_CLI": "1",
        ]

        #expect(
            ExecutableLaunch.destination(environment: environment)
                == .databaseBroker)
        #expect(!ExecutableLaunch.isApplication(environment: environment))
    }

    @Test func databaseBrokerLauncherStartsTheBroker() {
        #expect(
            ExecutableLaunch.destination(
                environment: ["EDITH_DATABASE_BROKER": "1"]
            ) == .databaseBroker)
    }

    @Test(arguments: ["", "0", "true", "yes"])
    func unrelatedValuesStartTheApplication(value: String) {
        for key in ["EDITH_DATABASE_BROKER", "EDITH_CLI"] {
            let environment = [key: value]
            #expect(
                ExecutableLaunch.destination(environment: environment)
                    == .application)
            #expect(ExecutableLaunch.isApplication(environment: environment))
        }
    }
}
