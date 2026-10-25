import Foundation
import Testing
@testable import MusicExtension

@Suite struct MusicCredentialIdentityTests {
    @Test(arguments: ["com.pulkit.edith.shared", "com.pulkit.edith.extensions.music"])
    func productionCredentialsAreIndependentOfPreferenceSuite(_ suite: String) {
        let prior = ["com.pulkit.edith.music": "synthetic-existing-session"]
        let service = MusicCredentialIdentity.service(
            applicationIdentifier: "com.pulkit.edith", isolatedIdentity: suite)
        #expect(prior[service] == "synthetic-existing-session")
    }

    @Test func isolatedIdentityIsPreserved() {
        #expect(
            MusicCredentialIdentity.service(
                applicationIdentifier: "com.pulkit.edith.dev.fixture",
                isolatedIdentity: "isolated.suite")
                == "isolated.suite.extension.music")
        #expect(
            MusicCredentialIdentity.service(applicationIdentifier: nil, isolatedIdentity: "fixture")
                == "fixture.extension.music")
    }
}
