import Foundation
import Security

enum UsageKeychain {
    private static let lock = NSLock()

    static func read(
        _ query: [String: Any],
        interactionAllowed: () -> Bool? = {
            var allowed = DarwinBoolean(false)
            guard SecKeychainGetUserInteractionAllowed(&allowed) == errSecSuccess else {
                return nil
            }
            return allowed.boolValue
        },
        setInteractionAllowed: (Bool) -> Bool = {
            SecKeychainSetUserInteractionAllowed($0) == errSecSuccess
        },
        copyItem: ([String: Any]) -> Data? = {
            var item: CFTypeRef?
            guard SecItemCopyMatching($0 as CFDictionary, &item) == errSecSuccess else {
                return nil
            }
            return item as? Data
        }
    ) -> Data? {
        lock.withLock {
            guard let allowed = interactionAllowed(), setInteractionAllowed(false) else {
                return nil
            }
            defer { _ = setInteractionAllowed(allowed) }
            return copyItem(query)
        }
    }
}
