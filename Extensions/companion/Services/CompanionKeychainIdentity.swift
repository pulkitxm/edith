import Foundation
import Security

enum CompanionKeychainIdentity {
    static func service(applicationIdentifier: String) -> String {
        applicationIdentifier == "com.pulkit.edith"
            ? "com.pulkit.edith.companion" : applicationIdentifier + ".extensions.companion"
    }

    static func query(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
