import Foundation
import Security

public struct KeychainJevKeyStore: JevKeyStore {
    public static let service = "com.pulkit.edith.jev"
    public static let account = "typesafe-api-key"

    public init() {}

    public func read() -> String? {
        var query = Self.baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
            let data = item as? Data
        else { return nil }
        let value = String(decoding: data, as: UTF8.self)
        return value.isEmpty ? nil : value
    }

    public func write(_ key: String?) {
        let query = Self.baseQuery()
        guard let key, !key.isEmpty else {
            SecItemDelete(query as CFDictionary)
            return
        }
        let data = Data(key.utf8)
        let status = SecItemUpdate(
            query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "Edith Jev"
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
