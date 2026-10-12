import Foundation
import Security
import Testing
@testable import CompanionExtension

@Suite struct CompanionCredentialIdentityTests {
    @Test(arguments: ["anthropicKey", "githubToken", "notionToken"])
    func originalAccountsRemainReadableThroughAnInjectedStore(_ account: String) {
        let prior = ["com.pulkit.edith.companion|" + account: "synthetic-existing-key"]
        let query = CompanionKeychainIdentity.query(
            service: CompanionKeychainIdentity.service(applicationIdentifier: "com.pulkit.edith"),
            account: account)
        let key =
            (query[kSecAttrService as String] as! String) + "|"
            + (query[kSecAttrAccount as String] as! String)
        #expect(prior[key] == "synthetic-existing-key")
    }

    @Test(arguments: ["com.pulkit.edith.dev.fixture", "com.pulkit.edith.tests.fixture"])
    func isolatedNamesStayIsolated(_ identifier: String) {
        #expect(
            CompanionKeychainIdentity.service(applicationIdentifier: identifier)
                == identifier + ".extensions.companion")
    }
}
