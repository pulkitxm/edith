import Foundation
import Security
import Testing
@testable import DatabaseCore

@Suite struct DatabaseCredentialIdentityTests {
    @Test func productionReadsTheOriginalSecretWithoutTouchingTheSystemKeychain() async throws {
        let secret = Data("synthetic-existing-password".utf8)
        let reference = DatabaseSecretReference(identifier: UUID(), purpose: .password)
        let account = DatabaseKeychainSecretStore.account(for: reference)
        let prior = ["com.pulkit.edith.database|" + account: secret]
        let api = DatabaseKeychainAPI(
            add: { _, _ in errSecParam },
            copyMatching: { query, result in
                let values = query as! [CFString: Any]
                let key =
                    (values[kSecAttrService] as! String) + "|"
                    + (values[kSecAttrAccount] as! String)
                guard let value = prior[key] else { return errSecItemNotFound }
                result?.pointee = value as CFData
                return errSecSuccess
            },
            update: { _, _ in errSecParam }, delete: { _ in errSecParam })
        let service = DatabaseKeychainSecretStore.service(
            applicationIdentifier: "com.pulkit.edith", isolatedSuffix: "database.secrets")
        let store = try DatabaseKeychainSecretStore(
            service: service, label: "Synthetic", maximumSecretBytes: 128, keychain: api)
        #expect(try await store.read(reference) == secret)
    }

    @Test(arguments: ["com.pulkit.edith.dev.fixture", "com.pulkit.edith.tests.fixture"])
    func isolatedSecretNamesRemainUnchanged(_ identifier: String) {
        #expect(
            DatabaseKeychainSecretStore.service(applicationIdentifier: identifier)
                == identifier + ".extensions.database")
        #expect(
            DatabaseKeychainSecretStore.service(
                applicationIdentifier: identifier, isolatedSuffix: "database.secrets")
                == identifier + ".database.secrets")
    }

}
