import Foundation
import LocalAuthentication
import Security

public struct KeychainJevKeyStore: JevKeyStore {
    public static let service = "com.pulkit.edith.jev"
    public static let account = "typesafe-api-key"

    public init() {}

    public func read() -> JevKeyRead {
        var query = Self.query()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        switch SecItemCopyMatching(query as CFDictionary, &item) {
        case errSecSuccess:
            guard let data = item as? Data, !data.isEmpty else { return .missing }
            return .key(String(decoding: data, as: UTF8.self))
        case errSecItemNotFound:
            return .missing
        default:
            return .unreadable
        }
    }

    public func write(_ key: String?) -> Bool {
        if read() != .missing {
            let removed = SecItemDelete(Self.query() as CFDictionary)
            guard removed == errSecSuccess || removed == errSecItemNotFound else { return false }
        }
        guard let key, !key.isEmpty else { return true }
        var add = Self.baseQuery()
        add[kSecValueData as String] = Data(key.utf8)
        add[kSecAttrLabel as String] = "Edith Jev"
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    private static func query() -> [String: Any] {
        var query = baseQuery()
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        return query
    }

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
