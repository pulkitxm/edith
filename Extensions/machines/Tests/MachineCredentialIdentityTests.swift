import Foundation
import Testing
@testable import MachinesExtension

@Suite struct MachineCredentialIdentityTests {
    @Test(arguments: ["com.pulkit.edith.shared", "com.pulkit.edith.extensions.machines"])
    func productionCredentialsAreIndependentOfPreferenceSuite(_ suite: String) {
        let prior = ["com.pulkit.edith.machines": "synthetic-existing-secret"]
        let service = MachineCredentialIdentity.service(
            applicationIdentifier: "com.pulkit.edith", defaultsSuite: suite)
        #expect(prior[service] == "synthetic-existing-secret")
    }

    @Test func isolatedSuitesAndFallbackRemainUnchanged() {
        #expect(
            MachineCredentialIdentity.service(
                applicationIdentifier: "com.pulkit.edith.dev.fixture",
                defaultsSuite: "isolated.suite")
                == "isolated.suite.machines")
        #expect(
            MachineCredentialIdentity.service(applicationIdentifier: nil, defaultsSuite: nil)
                == "edith.extension.tests.machines")
    }
}
