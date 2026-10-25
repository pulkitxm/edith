import Foundation
import Security
import Testing
@testable import JevExtension

@Suite struct JevCredentialIdentityTests {
    @Test func productionQueryFindsTheOriginalAccountInAnInjectedStore() {
        let store = KeychainJevKeyStore(
            service: KeychainJevKeyStore.service(
                applicationIdentifier: "com.pulkit.edith"))
        let query = store.baseQuery()
        let prior = ["com.pulkit.edith.jev|typesafe-api-key": "synthetic-existing-key"]
        let key =
            (query[kSecAttrService as String] as! String) + "|"
            + (query[kSecAttrAccount as String] as! String)
        #expect(prior[key] == "synthetic-existing-key")
        #expect(query[kSecClass as String] as! CFString == kSecClassGenericPassword)
    }

    @Test(arguments: ["com.pulkit.edith.dev.fixture", "com.pulkit.edith.tests.fixture"])
    func isolatedNamesStayIsolated(_ identifier: String) {
        #expect(
            KeychainJevKeyStore.service(applicationIdentifier: identifier)
                == identifier + ".extensions.jev")
    }
}
